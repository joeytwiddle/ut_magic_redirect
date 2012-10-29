#!/usr/bin/env coffee
appName = "UT Magic Redirect"
# A UT redirect server which can serve files sourced from multiple remote redirects.
# Copyright 2012 Paul Clark released under AGPL

# Keeps file data (blobs) in memory whilst the file is still streaming.

# DONE: Write to and read from a disk-cache.
# TODO: Cache maintainance.
# TODO: Hold (persistent?) "hint" data, which tells us where we have previously seen a file, so we can try that redirect first and avoid hitting 404s on the others.
# DONE: Better header passing so Unreal doesn't barf on the files it receives.  Saved in cacheEntry.responseHeaders.
# DONE: Require absolute path to cacheDir because initscript does not provide working folder.
# DONE: doNotCacheFrom may be used to prevent caching from one of the redirects

fs = require('fs')
http = require('http')
urllib = require('url')

options =
	listenPort: 4567
	validPath: "/([^/]*\\.(u|uz|u..))"
	# We will only accept requests matching the validPath regexp.
	# The matching part of the path inside the ()s is the filename; this will be appended to the redirect URLs.
	# If you want to use this proxy for more general purpose mirroring, try validPath: "/(.*)"
	# Note however that getCacheFilename() may need support for weird chars.
	useDiskCache: false
	cacheDir: "/home/redirect/cache"
	redirectList: [
		"http://localhost/uz/"
		"http://uz.ut-files.com/"
		"http://liandri.com/redirect/UT99/"
		# ... add more here ...
	]
	doNotCacheFrom: "http://localhost/uz/"

appStatus =
	cache: {}



if options.useDiskCache
	fs.readdir options.cacheDir, (err,files) ->
		if err
			fs.mkdirSync options.cacheDir, undefined, (err2) ->
				LOG("Error creating directory: "+options.cacheDir)
				console.log(err2)
		else
			LOG("Cache folder exists with "+files.length+" files.")



LOG = (x...) -> console.log("["+getDateString()+"]",x...)

getDateString = -> Date().split(" ").slice(1,5).join(" ")



mainRequestHandler = (request, response) ->
	try
		url = require("url").parse(request.url,true)
		LOG(">> "+request.method+" "+url.pathname+" from "+request.socket.remoteAddress)
		match = url.pathname.match('^'+options.validPath+'$')
		if !match
			failWithError(501,response,"We don't serve that kind of thing here, sir.")
		else
			filename = match[1]
			serveFile(filename, request, response)
	catch e
		LOG("Error handling request: "+e)
		response.writeHead(502,"text/plain")
		response.end("Error handling request: "+e+"\n") # body allowed in 502?
		throw e


serveFile = (filename, request, response) ->
	cacheEntry = getCacheEntry(filename)
	action = actionForStatus[cacheEntry.status]
	if !action
		failWithError(501,response,"Cannot serve since cacheEntry.status="+cacheEntry.status)
	else
		action(filename, cacheEntry, request, response)


getCacheEntry = (filename) ->
	cacheEntry = appStatus.cache[filename]
	if !cacheEntry
		cacheEntry =
			status: "unknown"
			attachedClients: []
			blobsReceived: []
		appStatus.cache[filename] = cacheEntry
	return cacheEntry


Actions =

	lookFor: (filename, cacheEntry, request, response) ->
		cacheEntry.status = "in_progress"
		cacheEntry.attachedClients.push(response)
		myList = options.redirectList.slice(0)
		tryNext = () ->
			nextRedirect = myList.shift()
			if !nextRedirect
				LOG("Failed to find \""+filename+"\" on any redirect, aborting "+cacheEntry.attachedClients.length+" clients.")
				cacheEntry.status = "cannot_find"
				for client in cacheEntry.attachedClients
					failWithError(404,client,null)   # "Sorry, not found on any redirects: "+filename)
			else
				targetHost = nextRedirect.split("/")[2]
				targetURL = nextRedirect + filename
				LOG("|| >> GET "+targetURL)
				reqOpts = urllib.parse(targetURL)
				reqOpts.headers = request.headers
				delete reqOpts.headers.host
				# delete reqOpts.headers.Host
				# console.log("|| Request options:")
				# console.log(reqOpts)
				outgoingRequest = http.request reqOpts, (incomingResponse) ->
					LOG("|| << Got response "+incomingResponse.statusCode)
					if incomingResponse.statusCode != 200
						LOG(" - That's a failure.")
						tryNext()
					else
						## Someone is giving us a file - yippee!
						LOG(" * Found "+filename+" on "+nextRedirect)
						pipeStream(filename,incomingResponse,cacheEntry,nextRedirect == options.doNotCacheFrom)
				outgoingRequest.end()
		tryNext()

	joinStream: (filename, cacheEntry, request, response) ->
		LOG("<< New client joining stream for "+filename+", sending "+cacheEntry.blobsReceived.length+" blobs.")
		response.writeHead(200, cacheEntry.responseHeaders)
		for data in cacheEntry.blobsReceived
			response.write(data)
		## We have given the client everything we got so far, but there may still be more to come
		cacheEntry.attachedClients.push(response)

	sendFromMem: (filename, cacheEntry, request, response) ->
		LOG("<< Unusual!  Client joined while writing cache-file.  Sending blobs.")
		response.writeHead(200, cacheEntry.responseHeaders)
		for data in cacheEntry.blobsReceived
			response.write(data)
		response.end()

	sendFromDisk: (filename, cacheEntry, request, response) ->
		cacheFile = getCacheFilename(filename)
		LOG("<< Sending from disk: "+cacheFile)
		response.writeHead(200, cacheEntry.responseHeaders)
		fs.readFile cacheFile, null, (err,data) ->
			response.write(data)
			response.end()
			LOG(" * Wrote "+data.length+" bytes to "+request.socket.remoteAddress)


actionForStatus =
	unknown:     Actions.lookFor
	in_progress: Actions.joinStream
	writing_now: Actions.sendFromMem
	on_disk:     Actions.sendFromDisk
	cannot_find: null


pipeStream = (filename,incomingResponse,cacheEntry,dontCache) ->
	LOG("<< Sending "+filename+" to "+cacheEntry.attachedClients.length+" clients.")
	httpResponseHeaders = incomingResponse.headers
	cacheEntry.responseHeaders = httpResponseHeaders
	for client in cacheEntry.attachedClients
		client.writeHead(200, httpResponseHeaders)
	incomingResponse.on 'data', (data) ->
		cacheEntry.blobsReceived.push(data)
		for client in cacheEntry.attachedClients
			client.write(data)
	incomingResponse.on 'end', () ->
		for client in cacheEntry.attachedClients
			client.end()
		LOG(" * Served "+filename+" to "+cacheEntry.attachedClients.length+" clients.")
		cacheEntry.attachedClients = []
		## Now we might want to write the blobs to a file
		if options.useDiskCache && !dontCache
			cacheEntry.status = "writing_now"
			cacheFile = getCacheFilename(filename)
			writeBlobsToFile cacheEntry.blobsReceived,cacheFile,() ->
				LOG(" * Saved "+cacheEntry.blobsReceived.length+" blobs (size "+sumLengths(cacheEntry.blobsReceived)+") to file "+cacheFile)
				cacheEntry.status = "on_disk"
				cacheEntry.blobsReceived = []
		else
		## Otherwise we just forget them, to reclaim memory
			LOG(" * Forgetting "+cacheEntry.blobsReceived.length+" blobs (size "+sumLengths(cacheEntry.blobsReceived)+")")
			cacheEntry.status = "unknown"
			cacheEntry.blobsReceived = []


getCacheFilename = (filename) -> options.cacheDir + "/" + filename.replace("/","#","g")


failWithError = (errCode,response,message) ->
	LOG("Failing client "+response.socket.remoteAddress+" with: "+message)
	response.writeHead(errCode,"text/plain")
	if message == null
		response.end()
	else
		response.end(message+"\n")


sumLengths = (bloblist) ->
	bloblist.map( (blob) -> blob.length ).reduce( (a,b) -> a+b )


writeBlobsToFile = (blobs,filename,whenDone) ->
	fs.open filename,"w", (err,fd) ->
		i = 0
		doNextBit = () ->
			if i < blobs.length
				fs.write(fd,blobs[i],0,blobs[i].length,null,afterBit)
			else
				fs.close(fd,whenDone)
		afterBit = () ->
			i++
			doNextBit()
		doNextBit()


http.createServer(mainRequestHandler).listen(options.listenPort)
LOG(appName+' running at http://127.0.0.1:'+options.listenPort+'/')



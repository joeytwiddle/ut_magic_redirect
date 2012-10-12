#!/usr/local/node/bin/coffee
appName = "UT Magic Redirect"
# A UT redirect server which can serve files sourced from multiple remote redirects.
# Copyright 2012 Paul Clark released under AGPL

# This version does not cache retrieved files on disk anywhere, or have any persistent data.
# However it does keep file data (blobs) in memory whilst the file is still streaming.

# TODO: Write to and read from a disk-cache, and cache maintainance.
# TODO: Hold (persistent?) "hint" data, which tells us where we have previously seen a file, so we can try that redirect first and avoid hitting 404s on the others.

listenPort = 4567

http = require('http')


appStatus =
	cache: {}
	options:
		redirectList: [
			"http://uz.ut-files.com/"
			"http://liandri.com/redirect/UT99/"
			# ... add more here ...
			"http://5.45.182.78/uz/"
		]


LOG = (x...) -> console.log(x...)


mainRequestHandler = (request, response) ->
	try
		url = require("url").parse(request.url,true)
		LOG(">> "+request.method+" "+url.pathname+" from "+request.socket.remoteAddress)
		filename = url.pathname
		if filename[0] != "/"
			LOG("Odd - missing leading / in path: url="+url+" path="+url.pathname)
		else
			filename = filename.slice(1)
		# We are expecting a single filename, no subdirectories
		if filename.indexOf("/")>=0
			failWithError(501,response,"We don't serve that kind of thing here, sir.")
		else
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
		myList = appStatus.options.redirectList.slice(0)
		tryNext = () ->
			nextRedirect = myList.shift()
			if !nextRedirect
				LOG("Failed to find \""+filename+"\" on any redirect, aborting "+cacheEntry.attachedClients.length+" clients.")
				cacheEntry.status = "cannot_find"
				for client in cacheEntry.attachedClients
					failWithError(404,client,"Sorry, not found on any redirects: "+filename)
			else
				targetHost = nextRedirect.split("/")[2]
				targetURL = nextRedirect + filename
				LOG("|| >> GET "+targetURL)
				outgoingRequest = http.request targetURL, (incomingResponse) ->
					LOG("|| << Got response "+incomingResponse.statusCode)
					if incomingResponse.statusCode != 200
						LOG(" - That's a failure.")
						tryNext()
					else
						## Someone is giving us a file - yippee!
						LOG(" * Found "+filename+" on "+nextRedirect)
						pipeStream(filename,incomingResponse,cacheEntry)
				outgoingRequest.end()
		tryNext()

	joinStream: (filename, cacheEntry, request, response) ->
		LOG("<< New client joining stream for "+filename+", sending "+cacheEntry.blobsReceived.length+" blobs.")
		httpResponseHeaders = {}
		httpResponseHeaders["content-type"] = "data/plain" # I dunno :P
		response.writeHead(200, httpResponseHeaders)
		for data in cacheEntry.blobsReceived
			response.write(data)
		## We have given the client everything we got so far, but there may still be more to come
		cacheEntry.attachedClients.push(response)


actionForStatus =
	unknown:     Actions.lookFor
	in_progress: Actions.joinStream
	on_disk:     null # Actions.sendFromDisk
	cannot_find: null


# I wrapped all client output in try-catch, just in case it errors on premature
# client disconnect, although I have never seen such errors!
pipeStream = (filename,incomingResponse,cacheEntry) ->
	LOG("<< Sending "+filename+" to "+cacheEntry.attachedClients.length+" clients.")
	httpResponseHeaders = incomingResponse.headers
	for client in cacheEntry.attachedClients
		try client.writeHead(200, httpResponseHeaders)
		catch e
			LOG("Error on client.writeHead",e)
	incomingResponse.on 'data', (data) ->
		cacheEntry.blobsReceived.push(data)
		for client in cacheEntry.attachedClients
			try client.write(data)
			catch e
				LOG("Error on client.write",e)
	incomingResponse.on 'end', () ->
		for client in cacheEntry.attachedClients
			try client.end()
			catch e
				LOG("Error on client.end",e)
		LOG(" * Served "+filename+" to "+cacheEntry.attachedClients.length+" clients.")
		LOG(" * Forgetting "+cacheEntry.blobsReceived.length+" blobs (size "+sumLengths(cacheEntry.blobsReceived)+")")
		cacheEntry.attachedClients = []
		## Now we might want to write the blobs to a file
		# ...
		# cacheEntry.blobsReceived = []
		# cacheEntry.status = "on_disk"
		#
		## For the moment, do nothing
		cacheEntry.blobsReceived = []
		cacheEntry.status = "unknown"
		## We could keeps the blobs around, and set the status="in_memory"
		## But we will want to clean up memory now and then!
		## For that extra complexity, we may as well start maintaining a disk cache.


failWithError = (errCode,response,message) ->
	LOG("Failing client "+request.socket.remoteAddress+" with: "+message)
	response.writeHead(errCode,"text/plain")
	response.end(message+"\n")


sumLengths = (bloblist) ->
	bloblist.map( (blob) -> blob.length ).reduce( (a,b) -> a+b )


http.createServer(mainRequestHandler).listen(listenPort)
LOG(appName+' running at http://127.0.0.1:'+listenPort+'/')



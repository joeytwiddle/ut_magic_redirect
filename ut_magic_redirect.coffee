#!/usr/local/node/bin/coffee
appName = "UT Magic Redirect"
# A UT redirect server which can serve files sourced from multiple remote redirects.
# Copyright 2012 Paul Clark released under AGPL

# This version does not cache retrieved files on disk anywhere, or have any persistent data.
# However it does keep file data (blobs) in memory whilst the file is still streaming.

listenPort = 8080

http = require('http')
net = require('net')

appStatus =
	cache: {}
	options:
		redirectList: [
			"http://uz.ut-files.com/"
			"http://liandri.com/redirect/UT99/"
			"http://5.45.182.78/uz/"
			# ... add more here ...
		]

LOG = (x...) -> console.log(x...)

mainRequestHandler = (request, response) ->
	try
		url = require("url").parse(request.url,true)
		filename = url.pathname
		if filename[0] != "/"
			LOG("Odd - missing leading / in path: url="+url+" path="+url.pathname)
		else
			filename = filename.slice(1)
		if filename.indexOf("/")>=0
			LOG("Unexpected / in filename: "+filename)
			LOG("We don't serve this kind of request: "+request.method+" "+request.url)
			response.writeHead(501,"text/plain")
			response.end("We don't serve that kind of thing here, sir.\n")
		else
			serveUTFile(filename, request, response)
	catch e
		LOG("Error handling request: "+e)
		response.writeHead(502,"text/plain")
		response.end("Error handling request: "+e+"\n") # body allowed in 502?
		throw e

getCacheEntry = (filename) ->
	cacheEntry = appStatus.cache[filename]
	if !cacheEntry
		cacheEntry =
			status: "unknown"
			attachedClients: []
			blobsReceived: []
		appStatus.cache[filename] = cacheEntry
	return cacheEntry

serveUTFile = (filename, request, response) ->
	cacheEntry = getCacheEntry(filename)
	if cacheEntry.status == "in_progress"
		joinStream(filename, cacheEntry, request, response)
	else if cacheEntry.status == "on_disk"
		sendFromDisk(filename, cacheEntry, request, response)
	else if cacheEntry.status == "unknown"
		lookFor(filename, cacheEntry, request, response)

lookFor = (filename, cacheEntry, request, response) ->
	cacheEntry.status = "in_progress"
	cacheEntry.attachedClients.push(response)
	myList = appStatus.options.redirectList.slice(0)
	tryNext = () ->
		nextRedirect = myList.shift()
		if !nextRedirect
			LOG("FAILED ON ALL REDIRECTS, ABORTING: "+filename)
			for client in cacheEntry.attachedClients
				client.writeHead(404,"text/plain")
				client.end("Sorry, not found on any redirects: "+filename)
		else
			targetHost = nextRedirect.split("/")[2]
			targetURL = nextRedirect + filename
			outgoingHeaders =
				host: targetHost
			LOG("|| >> GET "+targetURL)
			ogrOptions =
				method: "GET"
				headers: outgoingHeaders
				host: targetHost
				path: "/" + filename ## WRONG!
			# httpClient = http.createClient(80,outgoingHeaders.host)
			outgoingRequest = http.request targetURL, (incomingResponse) ->
			# outgoingRequest = http.request ogrOptions, (incomingResponse) ->
				LOG("|| << Got response "+incomingResponse.statusCode)
				if incomingResponse.statusCode != 200
					LOG("|| That's a failure.")
					tryNext()
				else
					## Someone is giving us a file - yippee!
					httpResponseHeaders = {}
					httpResponseHeaders["content-type"] = "data/plain" # I dunno :P
					for client in cacheEntry.attachedClients
						client.writeHead(200, httpResponseHeaders)
					incomingResponse.on 'data', (data) ->
						cacheEntry.blobsReceived.push(data)
						for client in cacheEntry.attachedClients
							client.write(data)
					incomingResponse.on 'end', () ->
						for client in cacheEntry.attachedClients
							client.end()
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
			outgoingRequest.end()
	tryNext()

joinStream = (filename, cacheEntry, request, response) ->
	httpResponseHeaders = {}
	httpResponseHeaders["content-type"] = "data/plain" # I dunno :P
	response.writeHead(200, httpResponseHeaders)
	for data in cacheEntry.blobsReceived
		response.write(data)
	## We have given the client everything we got so far, but there may still be more to come
	cacheEntry.attachedClients.push(response)


http.createServer(mainRequestHandler).listen(listenPort)
LOG(appName+' running at http://127.0.0.1:'+listenPort+'/')



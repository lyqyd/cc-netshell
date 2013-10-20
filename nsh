local tArgs = { ... }

local connections = {}

local nshAPI = {
	connList = connections
}

if not framebuffer then if not (os.loadAPI("framebuffer") or os.loadAPI("LyqydOS/framebuffer")) then error("Could not find framebuffer API!", 0) end end

nshAPI.getRemoteID = function()
	--check for connected clients with matching threads.
	for cNum, cInfo in pairs(nshAPI.connList) do
		if cInfo.thread == coroutine.running() then
			if cNum == "localShell" then
				--if we are a client running on the server, return the remote server ID.
				if nshAPI.serverNum then
					return nshAPI.serverNum
				else
					return nil
				end
			end
			return cNum
		end
	end
	--client running without local server, return remote server ID.
	if nshAPI.serverNum then return nshAPI.serverNum end
	return nil
end

nshAPI.send = function(msg)
	local id = nshAPI.getRemoteID()
	if id then
		return rednet.send(id, msg)
	end
	return nil
end

nshAPI.receive = function(timeout)
	if type(timeout) == number then timeout = os.startTimer(timeout) end
	while true do
		event = {os.pullEvent()}
		if event[1] == "rednet_message" and event[2] == nshAPI.getRemoteID() then
			return event[3]
		elseif event[1] == "timer" and event[2] == timeout then
			return nil
		end
	end
end

nshAPI.getClientCapabilities = function()
	if nshAPI.clientCapabilities then return nshAPI.clientCapabilities end
	nshAPI.send("SP:;clientCapabilities")
	return nshAPI.receive(1)
end

nshAPI.getRemoteConnections = function()
	local remotes = {}
	for cNum, cInfo in pairs(nshAPI.connList) do
		table.insert(remotes, cNum)
		if cInfo.outbound then
			table.insert(remotes, cInfo.outbound)
		end
	end
	return remotes
end

nshAPI.packFile = function(path)
	local data = {}
	local count = 0
	local handle = io.open(path, "rb")
	if handle then
		local byte = handle:read()
		repeat
			data[#data + 1] = byte
			count = count + 1
			if count % 1000 == 0 then
				os.queueEvent("yield")
				os.pullEvent("yield")
			end
			byte = handle:read()
		until not byte
		handle:close()
	else
		return false
	end
	local outputTable = {}
	for i = 1, #data, 3 do
		local num1, num2, num3 = data[i], data[i + 1] or 0, data[i + 2] or 0
		table.insert(outputTable, string.char(bit.band(bit.brshift(num1, 2), 63)))
		table.insert(outputTable, string.char(bit.bor(bit.band(bit.blshift(num1, 4), 48), bit.band(bit.brshift(num2, 4), 15))))
		table.insert(outputTable, string.char(bit.bor(bit.band(bit.blshift(num2, 2), 60), bit.band(bit.brshift(num3, 6), 3))))
		table.insert(outputTable, string.char(bit.band(num3, 63)))
	end
	--mark non-data (invalid) bytes
	if #data % 3 == 1 then
		outputTable[#outputTable] = "="
		outputTable[#outputTable - 1] = "="
	elseif #data % 3 == 2 then
		outputTable[#outputTable] = "="
	end
	return table.concat(outputTable, "")
end

nshAPI.unpackAndSaveFile = function(path, data)
	local outputTable = {}
	for i=1, #data, 4 do
		local char1, char2, char3, char4 = string.byte(string.sub(data, i, i)), string.byte(string.sub(data, i + 1, i + 1)), string.byte(string.sub(data, i + 2, i + 2)), string.byte(string.sub(data, i + 3, i + 3))
		table.insert(outputTable, bit.band(bit.bor(bit.blshift(char1, 2), bit.brshift(char2, 4)), 255))
		table.insert(outputTable, bit.band(bit.bor(bit.blshift(char2, 4), bit.brshift(char3, 2)), 255))
		table.insert(outputTable, bit.band(bit.bor(bit.blshift(char3, 6), char4), 255))
	end
	--clean invalid bytes if marked
	if string.sub(data, #data, #data) == "=" then
		table.remove(outputTable)
		if string.sub(data, #data - 1, #data - 1) == "=" then
			table.remove(outputTable)
		end
	end
	local handle = io.open(path, "wb")
	if handle then
		for i = 1, #outputTable do
			handle:write(outputTable[i])
			if i % 10 == 0 then
				os.startTimer(0.1)
				os.pullEvent("timer")
			end
		end
		handle:close()
	end
end

local packetConversion = {
	query = "SQ",
	response = "SR",
	data = "SP",
	close = "SC",
	fileQuery = "FQ",
	fileSend = "FS",
	fileResponse = "FR",
	fileHeader = "FH",
	fileData = "FD",
	fileEnd = "FE",
	textTable = "TT",
	event = "EV",
	SQ = "query",
	SR = "response",
	SP = "data",
	SC = "close",
	FQ = "fileQuery",
	FS = "fileSend",
	FR = "fileResponse",
	FH = "fileHeader",
	FD = "fileData",
	FE = "fileEnd",
	TT = "textTable",
	EV = "event",
}

local function openModem()
	local modemFound = false
	for _, side in ipairs(rs.getSides()) do
		if peripheral.getType(side) == "modem" then
			if not rednet.isOpen(side) then rednet.open(side) end
			modemFound = true
			break
		end
	end
	return modemFound
end

local function send(id, pType, message)
	if pType and message then
		return rednet.send(id, packetConversion[pType]..":;"..message)
	end
end

local function awaitResponse(id, time)
	id = tonumber(id)
	local listenTimeOut = nil
	local messRecv = false
	if time then listenTimeOut = os.startTimer(time) end
	while not messRecv do
		local event, p1, p2 = os.pullEvent()
		if event == "timer" and p1 == listenTimeOut then
			return false
		elseif event == "rednet_message" then
			sender, message = p1, p2
			if id == sender and message then
				if packetConversion[string.sub(message, 1, 2)] then packetType = packetConversion[string.sub(message, 1, 2)] end
				message = string.match(message, ";(.*)")
				messRecv = true
			end
		end
	end
	return packetType, message
end

local function processText(serverNum, pType, value)
	if pType == "textTable" then
		local linesTable = textutils.unserialize(value)
		for i=1, linesTable.sizeY do
			term.setCursorPos(1,i)
			local lineEnd = false
			local offset = 1
			while not lineEnd do
				local textColorString = string.match(string.sub(linesTable.textColor[i], offset), string.sub(linesTable.textColor[i], offset, offset).."*")
				local backColorString = string.match(string.sub(linesTable.backColor[i], offset), string.sub(linesTable.backColor[i], offset, offset).."*")
				term.setTextColor(2 ^ tonumber(string.sub(textColorString, 1, 1), 16))
				term.setBackgroundColor(2 ^ tonumber(string.sub(backColorString, 1, 1), 16))
				term.write(string.sub(linesTable.text[i], offset, offset + math.min(#textColorString, #backColorString) - 1))
				offset = offset + math.min(#textColorString, #backColorString)
				if offset > linesTable.sizeX then lineEnd = true end
			end
		end
		term.setCursorPos(linesTable.cursorX, linesTable.cursorY)
		term.setCursorBlink(linesTable.cursorBlink)
	end
end


local eventFilter = {
	key = true,
	char = true,
	mouse_click = true,
	mouse_drag = true,
	mouse_scroll = true,
}

local function newSession(x, y, color)
	local session = {}
	local path = "/rom/programs/shell"
	if #tArgs >= 2 and shell.resolveProgram(tArgs[2]) then path = shell.resolveProgram(tArgs[2]) end
	session.thread = coroutine.create(function() shell.run(path) end)
	session.target = framebuffer.new(x, y, color)
	session.status = "open"
	term.redirect(session.target)
	coroutine.resume(session.thread)
	term.restore()
	return session
end

if #tArgs >= 1 and tArgs[1] == "host" then
	_G.nsh = nshAPI
	if not openModem() then return end
	local connInfo = {}
	connInfo.target = term.native
	local path = "/rom/programs/shell"
	if #tArgs >= 3 and shell.resolveProgram(tArgs[3]) then path = shell.resolveProgram(tArgs[3]) end
	connInfo.thread = coroutine.create(function() shell.run(path) end)
	connections.localShell = connInfo
	term.clear()
	term.setCursorPos(1,1)
	coroutine.resume(connections.localShell.thread)

	while true do
		event = {os.pullEventRaw()}
		if event[1] == "rednet_message" then
			if packetConversion[string.sub(event[3], 1, 2)] then
				--this is a packet meant for us.
				conn = event[2]
				packetType = packetConversion[string.sub(event[3], 1, 2)]
				message = string.match(event[3], ";(.*)")
				if connections[conn] and connections[conn].status == "open" then
					if packetType == "event" or string.sub(packetType, 1, 4) == "text" then
						local eventTable = {}
						if packetType == "event" then
							eventTable = textutils.unserialize(message)
						else
							--we can pass the packet in raw, since this is not an event packet.
							eventTable = event
						end
						if not connections[conn].filter or eventTable[1] == connections[conn].filter then
							connections[conn].filter = nil
							term.redirect(connections[conn].target)
							passback = {coroutine.resume(connections[conn].thread, unpack(eventTable))}
							if passback[1] and passback[2] then
								connections[conn].filter = passback[2]
							end
							if coroutine.status(connections[conn].thread) == "dead" then
								send(conn, "close", "disconnect")
								table.remove(connections, conn)
							end
							term.restore()
							if connections[conn] then
								send(conn, "textTable", textutils.serialize(connections[conn].target.buffer))
							end
						end
					elseif packetType == "query" then
						local connType, color, x, y = string.match(message, "(%a+):(%a+);(%d+),(%d+)")
						if connType == "connect" then
							--reset connection
							send(conn, "response", "OK")
							connections[conn] = newSession(tonumber(x), tonumber(y), color == "true")
							send(conn, "textTable", textutils.serialize(connections[conn].target.buffer))
						elseif connType == "resume" then
							--restore connection
							send(conn, "response", "OK")
							send(conn, "textTable", textutils.serialize(connections[conn].target.buffer))
						end
					elseif packetType == "close" then
						table.remove(connections, conn)
						send(conn, "close", "disconnect")
						--close connection
					else
						--we got a packet, have an open connection, but despite it being in the conversion table, don't handle it ourselves. Send it onward.
						if not connections[conn].filter or eventTable[1] == connections[conn].filter then
							connections[conn].filter = nil
							term.redirect(connections[conn].target)
							passback = {coroutine.resume(connections[conn].thread, unpack(event))}
							if passback[2] then
								connections[conn].filter = passback[2]
							end
							if coroutine.status(connections[conn].thread) == "dead" then
								send(conn, "close", "disconnect")
								table.remove(connections, conn)
							end
							term.restore()
							send(conn, "textTable", textutils.serialize(connections[conn].target.buffer))
						end
					end
				elseif packetType ~= "query" then
					--usually, we would send a disconnect here, but this prevents one from hosting nsh and connecting to other computers.  Pass these to all shells as well.
					for cNum, cInfo in pairs(connections) do
						if not cInfo.filter or event[1] == cInfo.filter then
							cInfo.filter = nil
							term.redirect(cInfo.target)
							passback = {coroutine.resume(cInfo.thread, unpack(event))}
							if passback[2] then
								cInfo.filter = passback[2]
							end
							term.restore()
							if cNum ~= "localShell" then
								send(cNum, "textTable", textutils.serialize(cInfo.target.buffer))
							end
						end
					end
				else
					--open new connection
					send(conn, "response", "OK")
					local color, x, y = string.match(message, "connect:(%a+);(%d+),(%d+)")
					local connInfo = newSession(tonumber(x), tonumber(y), color == "true")
					send(conn, "textTable", textutils.serialize(connInfo.target.buffer))
					connections[conn] = connInfo
				end
			else
				--rednet message, but not in the correct format, so pass to all shells.
				for cNum, cInfo in pairs(connections) do
					if not cInfo.filter or event[1] == cInfo.filter then
						cInfo.filter = nil
						term.redirect(cInfo.target)
						passback = {coroutine.resume(cInfo.thread, unpack(event))}
						if passback[2] then
							cInfo.filter = passback[2]
						end
						term.restore()
					end
					if cNum ~= "localShell" then
						send(cNum, "textTable", textutils.serialize(cInfo.target.buffer))
					end
				end
			end
		elseif event[1] == "mouse_click" or event[1] == "mouse_drag" or event[1] == "mouse_scroll" or event[1] == "key" or event[1] == "char" then
			--user interaction.
			coroutine.resume(connections.localShell.thread, unpack(event))
			if coroutine.status(connections.localShell.thread) == "dead" then
				for cNum, cInfo in pairs(connections) do
					if cNum ~= "localShell" then
						send(cNum, "close", "disconnect")
					end
				end
				return
			end
		elseif event[1] == "terminate" then
			_G.nsh = nil
			return
		else
			--dispatch all other events to all shells
			for cNum, cInfo in pairs(connections) do
				if not cInfo.filter or event[1] == cInfo.filter then
					cInfo.filter = nil
					term.redirect(cInfo.target)
					passback = {coroutine.resume(cInfo.thread, unpack(event))}
					if passback[2] then
						cInfo.filter = passback[2]
					end
					term.restore()
					if cNum ~= "localShell" then
						send(cNum, "textTable", textutils.serialize(cInfo.target.buffer))
					end
				end
			end
		end
	end

elseif #tArgs <= 2 and nsh and nsh.getRemoteID() then
	print(nsh.getRemoteID())
	--forwarding mode
	local conns = nsh.getRemoteConnections()
	for i = 1, #conns do
		if conns[i] == serverNum then
			print("Cyclic connection refused.")
			return
		end
	end
	local fileTransferState = nil
	local fileData = nil
	local serverNum = tonumber(tArgs[1])
	send(serverNum, "query", "connect")
	local pType, message = awaitResponse(serverNum, 2)
	if pType ~= "response" then
		print("Connection Failed")
		return
	else
		nsh.connList[nsh.getRemoteID()].outbound = serverNum
		term.clear()
		term.setCursorPos(1,1)
	end
	local clientID = nsh.getRemoteID()
	local serverID = tonumber(tArgs[1])
	while true do
		event = {os.pullEvent()}
		if event[1] == "rednet_message" then
			if event[2] == clientID or event[2] == serverID then
				if event[2] == serverID and string.sub(event[3], 1, 2) == "SC" then break end
				rednet.send((event[2] == clientID and serverID or clientID), event[3])
			end
		elseif eventFilter[event[1]] then
			rednet.send(serverID, "EV:;"..textutils.serialize(event))
		end
	end
	nsh.connList[nsh.getRemoteID()].outbound = nil
	term.clear()
	term.setCursorPos(1, 1)
	print("Connection closed by server")

elseif #tArgs <= 2 then --either no server running or we are the local shell on the server.
	local serverNum = tonumber(tArgs[1])
	if nsh then
		local conns = nsh.getRemoteConnections()
		for i = 1, #conns do
			if conns[i] == serverNum then
				print("Connection refused.")
				return
			end
		end
	end
	local fileTransferState = nil
	local fileData = nil
	local fileBinaryData = nil
	local unpackCo = {}
	if not openModem() then return end
	local color = term.isColor()
	local x, y = term.getSize()
	if tArgs[2] == "resume" then
		send(serverNum, "query", "resume:"..tostring(color)..";"..tostring(x)..","..tostring(y))
	else
		send(serverNum, "query", "connect:"..tostring(color)..";"..tostring(x)..","..tostring(y))
	end
	local timeout = os.startTimer(2)
	while true do
		local event = {os.pullEvent()}
		if event[1] == "timer" and event[2] == timeout then
			print("Connection failed.")
			return
		elseif event[1] == "rednet_message" and event[2] == serverNum and string.sub(event[3], 1, 2) == "SR" then
			if nsh then nshAPI = nsh end
			if nshAPI.connList and nshAPI.connList.localShell then nshAPI.connList.localShell.outbound = serverNum end
			nshAPI.serverNum = serverNum
			nshAPI.clientCapabilities = "-fileTransfer-extensions-"
			term.clear()
			term.setCursorPos(1,1)
			break
		end
	end

	while true do
		event = {os.pullEventRaw()}
		if #unpackCo > 0 then
			for i = #unpackCo, 1, -1 do
				if coroutine.status(unpackCo[i]) ~= "dead" then
					coroutine.resume(unpackCo[i], unpack(event))
				else
					table.remove(unpackCo, i)
				end
			end
		end
		if event[1] == "rednet_message" and event[2] == serverNum then
			if packetConversion[string.sub(event[3], 1, 2)] then
				packetType = packetConversion[string.sub(event[3], 1, 2)]
				message = string.match(event[3], ";(.*)")
				if string.sub(packetType, 1, 4) == "text" then
					processText(serverNum, packetType, message)
				elseif packetType == "data" then
					if message == "clientCapabilities" then
						rednet.send(serverNum, nshAPI.clientCapabilities)
					end
				elseif packetType == "fileQuery" then
					--send a file to the server
					local mode, file = string.match(message, "^(%a)=(.*)")
					if fs.exists(file) then
						send(serverNum, "fileHeader", file)
						if mode == "b" then
							local fileString = nshAPI.packFile(file)
							send(serverNum, "fileData", "b="..fileString)
						else
							local handle = io.open(file, "r")
							if handle then
								send(serverNum, "fileData", "t="..handle:read("*a"))
								handle:close()
							end
						end
					else
						send(serverNum, "fileHeader", "fileNotFound")
					end
					send(serverNum, "fileEnd", "end")
				elseif packetType == "fileSend" then
					--receive a file from the server, but don't overwrite existing files.
					local mode, file = string.match(message, "^(%a)=(.*)")
					if not fs.exists(file) then
						fileTransferState = "receive_wait:"..file
						send(serverNum, "fileResponse", "ok")
						if mode == "b" then
							fileBinaryData = ""
							fileData = nil
						else
							fileData = ""
							fileBinaryData = nil
						end
					else
						send(serverNum, "fileResponse", "reject")
					end
				elseif packetType == "fileHeader" then
					if message == "fileNotFound" then
						fileTransferState = nil
					end
				elseif packetType == "fileData" then
					if fileTransferState and string.match(fileTransferState, "(.-):") == "receive_wait" then
						if string.match(message, "^(%a)=") == "b" then
							fileBinaryData = fileBinaryData..string.match(message, "^b=(.*)")
						else
							fileData = fileData..string.match(message, "^t=(.*)")
						end
					end
				elseif packetType == "fileEnd" then
					if fileTransferState and string.match(fileTransferState, "(.-):") == "receive_wait" then
						if fileBinaryData then
							local co = coroutine.create(nshAPI.unpackAndSaveFile)
							coroutine.resume(co, string.match(fileTransferState, ":(.*)"), fileBinaryData)
							if coroutine.status(co) ~= "dead" then
								table.insert(unpackCo, co)
							end
						elseif fileData then
							local handle = io.open(string.match(fileTransferState, ":(.*)"), "w")
							if handle then
								handle:write(fileData)
								handle:close()
							end
						end
						fileTransferState = nil
					end
				elseif packetType == "close" then
					if term.isColor() then
						term.setBackgroundColor(colors.black)
						term.setTextColor(colors.white)
					end
					term.clear()
					term.setCursorPos(1, 1)
					print("Connection closed by server.")
					nshAPI.serverNum = nil
					if nshAPI.connList and nshAPI.connList.localShell then nshAPI.connList.localShell.outbound = nil end
					return
				end
			end
		elseif event[1] == "mouse_click" or event[1] == "mouse_drag" or event[1] == "mouse_scroll" or event[1] == "key" or event[1] == "char" then
			--pack up event
			send(serverNum, "event", textutils.serialize(event))
		elseif event[1] == "terminate" then
			nshAPI.serverNum = nil
			if nshAPI.localShell then nshAPI.localShell.outbound = nil end
			term.clear()
			term.setCursorPos(1, 1)
			print("Connection closed locally.")
			return
		end
	end
else
	print("Usage: nsh <serverID>")
	print("       nsh host [remote [local]]")
end
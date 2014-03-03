local args = {...}

local connections = {}

local packetConversion = {
	query = "SQ",
	response = "SR",
	data = "SP",
	close = "SC",
	textTable = "TT",
	event = "EV",
	SQ = "query",
	SR = "response",
	SP = "data",
	SC = "close",
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

local function resumeThread(co, event)
	if not co.filter or event[1] == co.filter then
		co.filter = nil
		local passback = {coroutine.resume(co.thread, unpack(event))}
		if passback[1] and passback[2] then
			co.filter = passback[2]
		end
		if coroutine.status(co.thread) == "dead" then
			for cNum, cInfo in pairs(connections) do
				send(cNum, "close", "disconnect")
			end
			connections = {}
		end
		if connections[conn] and conn ~= "localShell" and framebuffer then
			for cNum, cInfo in pairs(connections) do
				send(cNum, "textTable", textutils.serialize(co.target.buffer))
			end
		end
	end
end

if not openModem() then error("No modem present!") end

if not framebuffer then if not os.loadAPI(shell.resolveProgram("framebuffer")) then error("Could not load framebuffer API") end end

local redirect, native = {}

if term.current then
	--we are using cc 1.6+.
	native = term.native()
else
	native = term.native
end
native.clear()
native.setCursorPos(1,1)
local x, y = native.getSize()

local _redirect = framebuffer.new(x, y, native.isColor())
for k, v in pairs(_redirect) do
	if type(k) == "string" and type(v) == "function" then
		redirect[k] = function(...)
			_redirect[k](...)
			return native[k](...)
		end
	else
		redirect[k] = _redirect[k]
	end
end

term.redirect(redirect)
if term.current then
	--1.6+
	term.native = function() return redirect end
else
	term.native = redirect
end

local shellRoutine = coroutine.create(function() shell.run("/rom/programs/shell", unpack(args)) end)
coroutine.resume(shellRoutine)

local co = {thread = shellRoutine, target = redirect}

while true do
	event = {os.pullEventRaw()}
	if event[1] == "rednet_message" then
		if packetConversion[string.sub(event[3], 1, 2)] then
			--this is a packet meant for us.
			conn = event[2]
			packetType = packetConversion[string.sub(event[3], 1, 2)]
			message = string.match(event[3], ";(.*)")
			if connections[conn] and connections[conn].status == "open" then
				if packetType == "event" then
					local eventTable = textutils.unserialize(message)
					resumeThread(co, eventTable)
				elseif packetType == "query" then
					connections[conn] = {status = "open"}
					send(conn, "response", "OK")
					send(conn, "textTable", textutils.serialize(co.target.buffer))
				elseif packetType == "close" then
					connections[conn] = nil
					send(conn, "close", "disconnect")
					--close connection
				end
			elseif packetType ~= "query" then
				--usually, we would send a disconnect here, but this prevents one from hosting nsh and connecting to other computers.  Pass these to all shells as well.
				resumeThread(co, event)
			else
				--open new connection
				connections[conn] = {status = "open"}
				send(conn, "response", "OK")
				send(conn, "textTable", textutils.serialize(co.target.buffer))
			end
		else
			--rednet message, but not in the correct format, so pass to all shells.
			resumeThread(co, event)
		end
	else
		--dispatch all other events to all shells
		resumeThread(co, event)
	end
end

if not nsh then print("No nsh session!") return end

local args = {...}

if #args < 2 then
	print("Usage: binget <remote> <local>")
	print("<remote>: any file on the server")
	print("<local>: any non-existant file on the client")
	return
end

if fs.exists(args[1]) then
	nsh.send("FS:;b="..args[2])
	local message = nsh.receive()
	if message == "FR:;ok" then
		nsh.send("FH:;"..args[1])
		nsh.send("FD:;b="..nsh.packFile(args[1]))
		nsh.send("FE:;end")
	else
		print("Client rejected file!")
	end
end
-- Argument: URL prefix. Switches to the first tab whose URL starts with it and
-- prints "found", or prints "missing".
on run argv
	set prefix to item 1 of argv
	tell application "Google Chrome"
		repeat with w in windows
			set urls to URL of tabs of w
			repeat with i from 1 to count of urls
				if (item i of urls) starts with prefix then
					set active tab index of w to i
					set index of w to 1
					activate
					return "found"
				end if
			end repeat
		end repeat
	end tell
	return "missing"
end run

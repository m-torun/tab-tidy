-- Arguments: target window id, then window id, tab id, window id, tab id, ...
-- Gathers the tabs at the end of the target window and prints how many were
-- left where they were.
--
-- Chrome's "move" command drops the page and leaves an empty tab behind, so
-- each tab is reopened from its URL in the target window and the original is
-- closed. Pages that can't be reloaded from a URL (data:, blob:) stay put.
on run argv
	set targetID to item 1 of argv
	set skipped to 0
	tell application "Google Chrome"
		set target to window id targetID
		set activeIndex to active tab index of target
		repeat with i from 2 to (count of argv) by 2
			try
				set original to tab id (item (i + 1) of argv) of window id (item i of argv)
				set tabURL to URL of original
				if tabURL starts with "data:" or tabURL starts with "blob:" then error "not reloadable"
				tell target to make new tab with properties {URL:tabURL}
				close original
			on error
				set skipped to skipped + 1
			end try
		end repeat
		set active tab index of target to activeIndex
	end tell
	return skipped
end run

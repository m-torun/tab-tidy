// Prints every Chrome window, front to back, with its tabs as JSON.
// Each property is fetched for all windows at once, which keeps this fast
// with hundreds of tabs.
function run() {
    const windows = Application("Google Chrome").windows;
    const ids = windows.id();
    const modes = windows.mode();
    const tabIDs = windows.tabs.id();
    const titles = windows.tabs.title();
    const urls = windows.tabs.url();
    return JSON.stringify(ids.map((id, w) => ({
        id: id,
        incognito: modes[w] === "incognito",
        tabs: tabIDs[w].map((tabID, t) => ({
            windowID: id,
            id: tabID,
            title: titles[w][t] || "",
            url: urls[w][t] || "",
        })),
    })));
}

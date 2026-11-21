// Force Quit Monitor (force-quit-gui, from swap-watchdog) runs from login,
// minimized, so it can be shown when memory runs out without starting
// anything. Minimized, it's out of the taskbar, Alt+Tab and the pager;
// shown (by swap-watchdog, or the menu's Force Quit Monitor), it's back in
// them. A Wayland app can't ask for that itself, so KWin does it here.
// README, "Force Quit Monitor".

function track(window) {
    if (window.resourceClass !== "force-quit-gui") {
        return;
    }
    function sync() {
        const hidden = window.minimized;
        window.skipTaskbar = hidden;
        window.skipSwitcher = hidden;
        window.skipPager = hidden;
    }
    sync();
    window.minimizedChanged.connect(sync);
}

workspace.windowAdded.connect(track);
workspace.windowList().forEach(track);

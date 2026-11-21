// Pins Falkon to the taskbar of users whose panel was made before it was a
// default launcher (the layout pins it for new ones: Containerfile, "Falkon
// on the taskbar"). Plasma runs each update script once per user, so
// unpinning it afterwards sticks.
const falkon = "applications:org.kde.falkon.desktop";

for (const panel of panels()) {
    for (const widget of panel.widgets()) {
        if (widget.type !== "org.kde.plasma.icontasks" && widget.type !== "org.kde.plasma.taskmanager") {
            continue;
        }
        widget.currentConfigGroup = ["General"];
        const launchers = widget.readConfig("launchers").toString().split(",").filter(l => l !== "");
        if (launchers.includes(falkon)) {
            continue;
        }
        // After the browser, where the layout puts it.
        const browser = launchers.indexOf("preferred://browser");
        launchers.splice(browser + 1, 0, falkon);
        widget.writeConfig("launchers", launchers);
        widget.reloadConfig();
    }
}

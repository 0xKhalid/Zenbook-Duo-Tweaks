(function () {
    "use strict";

    var PLUGIN_ID = "zenbookduospanbothscreens";
    var TOP_OUTPUT = "eDP-1";
    var BOTTOM_OUTPUT = "eDP-2";
    var RESTORE_REQUEST_KEY = "RestoreRequest";
    var EDGE_TOLERANCE = 4;
    var states = {};
    var attachedWindows = {};
    var applyingGeometry = false;
    var dragging = {};
    var internalMaximize = {};
    var pendingMaximize = {};
    var pendingRestore = {};
    var restoreRequest = String(readConfig(RESTORE_REQUEST_KEY, "0"));

    function log(message) {
        print(PLUGIN_ID + ": " + message);
    }

    function cloneRect(rect) {
        return {
            x: Number(rect.x),
            y: Number(rect.y),
            width: Number(rect.width),
            height: Number(rect.height),
        };
    }

    function validRect(rect) {
        return rect && isFinite(rect.x) && isFinite(rect.y)
            && isFinite(rect.width) && isFinite(rect.height)
            && rect.width > 0 && rect.height > 0;
    }

    function sameRect(left, right) {
        return validRect(left) && validRect(right)
            && Math.round(left.x) === Math.round(right.x)
            && Math.round(left.y) === Math.round(right.y)
            && Math.round(left.width) === Math.round(right.width)
            && Math.round(left.height) === Math.round(right.height);
    }

    function windowId(window) {
        return String(window.internalId);
    }

    function clearFlagSoon(flags, id) {
        callDBus(
            "org.freedesktop.DBus",
            "/",
            "org.freedesktop.DBus.Peer",
            "Ping",
            function () {
                delete flags[id];
            }
        );
    }

    function setMaximizeInternally(window, vertical, horizontal) {
        var id = windowId(window);
        internalMaximize[id] = true;
        window.setMaximize(vertical, horizontal);
        clearFlagSoon(internalMaximize, id);
    }

    function outputByName(name) {
        var screens = workspace.screens;
        for (var index = 0; index < screens.length; index++) {
            if (screens[index].name === name) {
                return screens[index];
            }
        }
        return null;
    }

    function builtins() {
        return {
            top: outputByName(TOP_OUTPUT),
            bottom: outputByName(BOTTOM_OUTPUT),
        };
    }

    function unionRect(first, second) {
        var left = Math.min(first.x, second.x);
        var top = Math.min(first.y, second.y);
        var right = Math.max(first.x + first.width, second.x + second.width);
        var bottom = Math.max(first.y + first.height, second.y + second.height);
        return {x: left, y: top, width: right - left, height: bottom - top};
    }

    function outputWorkArea(output) {
        if (!output) {
            return null;
        }
        try {
            return cloneRect(workspace.clientArea(KWin.MaximizeArea, output, workspace.currentDesktop));
        } catch (error) {
            return cloneRect(output.geometry);
        }
    }

    function combinedWorkArea() {
        var screens = builtins();
        if (!screens.top || !screens.bottom) {
            return null;
        }
        var topGeometry = cloneRect(screens.top.geometry);
        var bottomGeometry = cloneRect(screens.bottom.geometry);
        var combined = unionRect(topGeometry, bottomGeometry);
        var outerTopInset = 0;
        var candidates = [screens.top, screens.bottom];
        for (var index = 0; index < candidates.length; index++) {
            var outputGeometry = cloneRect(candidates[index].geometry);
            if (Math.abs(outputGeometry.y - combined.y) > EDGE_TOLERANCE) {
                continue;
            }
            var area = outputWorkArea(candidates[index]);
            outerTopInset = Math.max(outerTopInset, Math.max(0, area.y - outputGeometry.y));
        }
        combined.y += outerTopInset;
        combined.height -= outerTopInset;
        return combined;
    }

    function eligible(window) {
        return Boolean(window && window.managed && window.normalWindow
            && !window.specialWindow && !window.dialog && !window.transient
            && !window.fullScreen && window.resizeable && window.moveableAcrossScreens);
    }

    function maximizeState(window) {
        var vertical = false;
        var horizontal = false;
        if (typeof window.maximizedVertically === "boolean") {
            vertical = window.maximizedVertically;
        }
        if (typeof window.maximizedHorizontally === "boolean") {
            horizontal = window.maximizedHorizontally;
        }
        if (!vertical && !horizontal && typeof window.maximizeMode === "number") {
            vertical = (window.maximizeMode & 1) !== 0;
            horizontal = (window.maximizeMode & 2) !== 0;
        }
        return {vertical: vertical, horizontal: horizontal};
    }

    function relativeGeometry(geometry, outputGeometry) {
        return {
            x: (geometry.x - outputGeometry.x) / outputGeometry.width,
            y: (geometry.y - outputGeometry.y) / outputGeometry.height,
            width: geometry.width / outputGeometry.width,
            height: geometry.height / outputGeometry.height,
        };
    }

    function saveState(window) {
        var output = window.output;
        var geometry = cloneRect(window.frameGeometry);
        var maximized = maximizeState(window);
        if ((maximized.vertical || maximized.horizontal)
            && validRect(window.maximizeGeometryRestore)) {
            geometry = cloneRect(window.maximizeGeometryRestore);
        }
        var outputGeometry = output ? cloneRect(output.geometry) : cloneRect(window.frameGeometry);
        return {
            geometry: geometry,
            outputName: output ? output.name : TOP_OUTPUT,
            outputGeometry: outputGeometry,
            relative: relativeGeometry(geometry, outputGeometry),
            maximizedVertical: maximized.vertical,
            maximizedHorizontal: maximized.horizontal,
            noBorder: Boolean(window.noBorder),
            suspended: false,
        };
    }

    function clampGeometry(geometry, area) {
        var result = cloneRect(geometry);
        result.width = Math.min(result.width, area.width);
        result.height = Math.min(result.height, area.height);
        result.x = Math.max(area.x, Math.min(result.x, area.x + area.width - result.width));
        result.y = Math.max(area.y, Math.min(result.y, area.y + area.height - result.height));
        return result;
    }

    function translatedRestoreGeometry(state) {
        var output = outputByName(state.outputName) || outputByName(TOP_OUTPUT);
        if (!output) {
            return state.geometry;
        }
        var current = cloneRect(output.geometry);
        if (sameRect(current, state.outputGeometry)) {
            return clampGeometry(state.geometry, outputWorkArea(output));
        }
        return clampGeometry({
            x: current.x + (state.relative.x * current.width),
            y: current.y + (state.relative.y * current.height),
            width: state.relative.width * current.width,
            height: state.relative.height * current.height,
        }, outputWorkArea(output));
    }

    function setWindowGeometry(window, geometry) {
        if (!validRect(geometry)) {
            return false;
        }
        applyingGeometry = true;
        try {
            window.frameGeometry = geometry;
        } finally {
            applyingGeometry = false;
        }
        return true;
    }

    function spanWindow(window) {
        if (!eligible(window) || !windowIsOnBuiltin(window)) {
            return false;
        }
        var target = combinedWorkArea();
        if (!target) {
            return false;
        }
        var id = windowId(window);
        if (!states[id]) {
            states[id] = saveState(window);
        }
        setMaximizeInternally(window, false, false);
        states[id].suspended = false;
        setWindowGeometry(window, target);
        log("spanned window " + id + " to " + target.width + "x" + target.height);
        return true;
    }

    function restoreWindow(window) {
        var id = windowId(window);
        var state = states[id];
        if (!state) {
            return false;
        }
        setMaximizeInternally(window, false, false);
        setWindowGeometry(window, translatedRestoreGeometry(state));
        window.noBorder = state.noBorder;
        if (state.maximizedVertical || state.maximizedHorizontal) {
            setMaximizeInternally(window, state.maximizedVertical, state.maximizedHorizontal);
        }
        delete states[id];
        log("restored window " + id);
        return true;
    }

    function toggleWindow(window) {
        if (!window) {
            return false;
        }
        return states[windowId(window)] ? restoreWindow(window) : spanWindow(window);
    }

    function restoreAllWindows() {
        var current = workspace.stackingOrder;
        var windows = [];
        var restored = 0;
        for (var item = 0; item < current.length; item++) {
            windows.push(current[item]);
        }
        for (var index = 0; index < windows.length; index++) {
            if (states[windowId(windows[index])] && restoreWindow(windows[index])) {
                restored++;
            }
        }
        log("restore-all request completed; restored=" + restored);
    }

    function fitSuspendedWindow(window, state) {
        var top = outputByName(TOP_OUTPUT);
        if (!top) {
            return;
        }
        setMaximizeInternally(window, false, false);
        setWindowGeometry(window, outputWorkArea(top));
        state.suspended = true;
    }

    function reconcileSpannedWindows() {
        var combined = combinedWorkArea();
        var windows = workspace.stackingOrder;
        for (var index = 0; index < windows.length; index++) {
            var window = windows[index];
            var state = states[windowId(window)];
            if (!state) {
                continue;
            }
            if (combined) {
                setMaximizeInternally(window, false, false);
                setWindowGeometry(window, combined);
                state.suspended = false;
            } else {
                fitSuspendedWindow(window, state);
            }
        }
    }

    function clamp(value, minimum, maximum) {
        return Math.max(minimum, Math.min(value, maximum));
    }

    function tearOffWindow(window) {
        var id = windowId(window);
        var state = states[id];
        if (!state) {
            return false;
        }
        var cursor = workspace.cursorPos;
        var spanned = cloneRect(window.frameGeometry);
        var restored = translatedRestoreGeometry(state);
        var horizontalRatio = clamp((cursor.x - spanned.x) / spanned.width, 0.05, 0.95);
        var titleOffset = clamp(cursor.y - spanned.y, 0, Math.min(60, restored.height / 4));
        var output = outputByName(state.outputName)
            || workspace.screenAt(cursor)
            || outputByName(TOP_OUTPUT);
        var area = outputWorkArea(output);

        restored.x = cursor.x - (horizontalRatio * restored.width);
        restored.y = cursor.y - titleOffset;
        restored = clampGeometry(restored, area);

        setMaximizeInternally(window, false, false);
        setWindowGeometry(window, restored);
        window.noBorder = state.noBorder;
        delete states[id];
        log("tore off window " + id + " beneath the pointer");
        return true;
    }

    function fullMaximizeMode(mode) {
        var numeric = Number(mode);
        return isFinite(numeric) && (numeric & 3) === 3;
    }

    function windowIsOnBuiltin(window) {
        return window && window.output
            && (window.output.name === TOP_OUTPUT || window.output.name === BOTTOM_OUTPUT);
    }

    function aboutToChangeMaximize(window, mode) {
        var id = windowId(window);
        if (internalMaximize[id] || dragging[id] || !fullMaximizeMode(mode)) {
            return;
        }
        if (!combinedWorkArea() || !windowIsOnBuiltin(window) || !eligible(window)) {
            return;
        }
        if (states[id]) {
            pendingRestore[id] = true;
        } else {
            pendingMaximize[id] = saveState(window);
        }
    }

    function changedMaximize(window) {
        var id = windowId(window);
        if (internalMaximize[id] || dragging[id]) {
            delete pendingMaximize[id];
            delete pendingRestore[id];
            return;
        }
        if (pendingRestore[id]) {
            delete pendingRestore[id];
            delete pendingMaximize[id];
            setMaximizeInternally(window, false, false);
            restoreWindow(window);
            return;
        }
        if (pendingMaximize[id]) {
            var target = combinedWorkArea();
            if (!target) {
                delete pendingMaximize[id];
                return;
            }
            states[id] = pendingMaximize[id];
            delete pendingMaximize[id];
            setMaximizeInternally(window, false, false);
            states[id].suspended = false;
            setWindowGeometry(window, target);
            log("converted non-drag maximize to span for " + id);
        }
    }

    function attachWindow(window) {
        if (!window || attachedWindows[windowId(window)]) {
            return;
        }
        var id = windowId(window);
        attachedWindows[id] = true;
        window.interactiveMoveResizeStarted.connect(function () {
            if (window.move && eligible(window)) {
                dragging[id] = true;
                delete pendingMaximize[id];
                delete pendingRestore[id];
                tearOffWindow(window);
            }
        });
        window.interactiveMoveResizeFinished.connect(function () {
            clearFlagSoon(dragging, id);
        });
        window.maximizedAboutToChange.connect(function (mode) {
            aboutToChangeMaximize(window, mode);
        });
        window.maximizedChanged.connect(function () {
            changedMaximize(window);
        });
        window.closed.connect(function () {
            delete states[id];
            delete attachedWindows[id];
            delete dragging[id];
            delete internalMaximize[id];
            delete pendingMaximize[id];
            delete pendingRestore[id];
        });
    }

    function attachExistingWindows() {
        var windows = workspace.stackingOrder;
        for (var index = 0; index < windows.length; index++) {
            attachWindow(windows[index]);
        }
    }

    function handleConfigChanged() {
        var requested = String(readConfig(RESTORE_REQUEST_KEY, "0"));
        if (requested === restoreRequest) {
            return;
        }
        restoreRequest = requested;
        restoreAllWindows();
    }

    registerUserActionsMenu(function (window) {
        if ((!eligible(window) || !windowIsOnBuiltin(window) || !combinedWorkArea())
            && !states[windowId(window)]) {
            return null;
        }
        var spanned = Boolean(states[windowId(window)]);
        return {
            title: spanned ? "Restore Window" : "Span Both Screens",
            checkable: true,
            checked: spanned,
            triggered: function () {
                toggleWindow(window);
            },
        };
    });

    workspace.windowAdded.connect(attachWindow);
    workspace.screensChanged.connect(reconcileSpannedWindows);
    workspace.virtualScreenGeometryChanged.connect(reconcileSpannedWindows);
    try {
        options.configChanged.connect(handleConfigChanged);
    } catch (error) {
        log("warning: restore-all configuration hook is unavailable: " + error);
    }
    attachExistingWindows();
    reconcileSpannedWindows();
    log("loaded; built-in outputs active=" + Boolean(combinedWorkArea()));
}());

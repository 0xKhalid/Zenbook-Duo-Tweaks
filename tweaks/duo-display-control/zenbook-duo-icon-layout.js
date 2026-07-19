/*
 * Plasma Folder View layout reconciliation for zenbook-duo-display-control.
 *
 * The invoking shell script defines:
 *   ZENBOOK_PHASE: "prepare" or "fit"
 *   ZENBOOK_ORIENTATION: normal, bottom-up, left-up, or right-up
 *   ZENBOOK_TARGET_GEOMETRIES: built-in output geometries from KScreen
 *   ZENBOOK_DRY_RUN: true to report without writing
 */

var ZenbookDuoIconLayout = (function () {
    "use strict";

    const ICON_SIZES = [22, 32, 48, 64, 96, 128, 256];

    function integer(value, fallback) {
        const parsed = Number(value);
        return Number.isInteger(parsed) ? parsed : fallback;
    }

    function parseJsonObject(value) {
        if (typeof value !== "string" || value.length === 0) {
            return {};
        }
        const parsed = JSON.parse(value);
        if (parsed === null || Array.isArray(parsed) || typeof parsed !== "object") {
            throw new Error("expected a JSON object");
        }
        return parsed;
    }

    function parseKConfigList(value) {
        if (typeof value !== "string" || value.length === 0) {
            return [];
        }

        const result = [];
        let current = "";
        let escaped = false;
        for (let index = 0; index < value.length; index++) {
            const character = value[index];
            if (escaped) {
                current += character;
                escaped = false;
            } else if (character.charCodeAt(0) === 92) {
                escaped = true;
            } else if (character === ",") {
                result.push(current);
                current = "";
            } else {
                current += character;
            }
        }
        if (escaped) {
            current += String.fromCharCode(92);
        }
        result.push(current);
        return result;
    }

    function geometryKey(geometry) {
        return Math.round(geometry.width) + "x" + Math.round(geometry.height);
    }

    function geometryMatches(left, right) {
        return Math.round(left.x) === Math.round(right.x)
            && Math.round(left.y) === Math.round(right.y)
            && Math.round(left.width) === Math.round(right.width)
            && Math.round(left.height) === Math.round(right.height);
    }

    function currentDesktopGeometry(desktop) {
        const geometry = screenGeometry(desktop.screen);
        return {
            x: geometry.x,
            y: geometry.y,
            width: geometry.width,
            height: geometry.height,
        };
    }

    function isTargetDesktop(desktop, targetGeometries) {
        if (desktop.type !== "org.kde.plasma.folder" || desktop.screen < 0) {
            return false;
        }
        const geometry = currentDesktopGeometry(desktop);
        return targetGeometries.some(function (target) {
            return geometryMatches(geometry, target);
        });
    }

    function parsePositionProfile(profile) {
        if (!Array.isArray(profile) || profile.length < 2 || (profile.length - 2) % 3 !== 0) {
            throw new Error("invalid Folder View position profile length");
        }

        const declaredStripes = integer(profile[0], -1);
        const perStripe = integer(profile[1], -1);
        if (declaredStripes < 1 || perStripe < 1) {
            throw new Error("invalid Folder View position header");
        }

        const entries = [];
        for (let index = 2; index < profile.length; index += 3) {
            const filename = profile[index];
            const stripe = integer(profile[index + 1], -1);
            const position = integer(profile[index + 2], -1);
            if (typeof filename !== "string" || filename.length === 0) {
                throw new Error("invalid Folder View filename");
            }
            entries.push({filename: filename, stripe: stripe, position: position});
        }
        return {declaredStripes: declaredStripes, perStripe: perStripe, entries: entries};
    }

    function serializePositionProfile(profile) {
        let usedStripes = 1;
        profile.entries.forEach(function (entry) {
            usedStripes = Math.max(usedStripes, entry.stripe + 1);
        });

        const serialized = [String(usedStripes), String(profile.perStripe)];
        profile.entries.forEach(function (entry) {
            serialized.push(entry.filename, String(entry.stripe), String(entry.position));
        });
        return serialized;
    }

    function gridCapacity(desktop, geometry, perStripe) {
        desktop.currentConfigGroup = ["General"];
        const iconSizeIndex = Math.max(0, Math.min(ICON_SIZES.length - 1, integer(desktop.readConfig("iconSize", 3), 3)));
        const labelWidth = Math.max(0, Math.min(2, integer(desktop.readConfig("labelWidth", 1), 1)));
        const textLines = Math.max(1, integer(desktop.readConfig("textLines", 2), 2));
        const arrangement = integer(desktop.readConfig("arrangement", 0), 0);
        const iconSize = ICON_SIZES[iconSizeIndex];
        const smallSpacing = Math.max(2, Math.ceil(gridUnit / 4));
        const cellWidth = Math.max(
            iconSize + (2 * gridUnit) + (2 * smallSpacing),
            16 * ((labelWidth * 2) + 4)
        );
        const cellHeight = iconSize + (gridUnit * textLines) + (smallSpacing * 3);
        let availableWidth = geometry.width;
        let availableHeight = geometry.height;
        panels().forEach(function (panel) {
            if (panel.screen !== desktop.screen || panel.hiding !== "none") {
                return;
            }
            if (panel.location === "left" || panel.location === "right") {
                availableWidth -= panel.height;
            } else if (panel.location === "top" || panel.location === "bottom") {
                availableHeight -= panel.height;
            }
        });
        const calculatedColumns = Math.max(1, Math.floor(availableWidth / cellWidth));
        const calculatedRows = Math.max(1, Math.floor(availableHeight / cellHeight));

        // Rows flow left-to-right; columns flow top-to-bottom. The stored
        // perStripe value is Plasma's exact capacity in the flow direction and
        // already accounts for panels and the live viewport.
        const maxStripes = arrangement === 1 ? calculatedColumns : calculatedRows;
        return {
            arrangement: arrangement,
            perStripe: perStripe,
            maxStripes: maxStripes,
            slots: perStripe * maxStripes,
        };
    }

    function reconcileProfile(profile, capacity) {
        const occupied = {};
        const filenames = {};
        const kept = [];
        const pending = [];
        let duplicates = 0;

        profile.entries.forEach(function (entry) {
            if (filenames[entry.filename]) {
                duplicates++;
                return;
            }
            filenames[entry.filename] = true;

            const cell = entry.stripe + ":" + entry.position;
            const valid = entry.stripe >= 0
                && entry.stripe < capacity.maxStripes
                && entry.position >= 0
                && entry.position < capacity.perStripe
                && !occupied[cell];
            if (valid) {
                occupied[cell] = true;
                kept.push(entry);
            } else {
                pending.push(entry);
            }
        });

        const free = [];
        for (let stripe = 0; stripe < capacity.maxStripes; stripe++) {
            for (let position = 0; position < capacity.perStripe; position++) {
                const cell = stripe + ":" + position;
                if (!occupied[cell]) {
                    free.push({stripe: stripe, position: position});
                }
            }
        }

        const moved = [];
        const overflow = [];
        pending.forEach(function (entry) {
            if (free.length === 0) {
                overflow.push(entry);
                return;
            }
            const destination = free.shift();
            moved.push({
                filename: entry.filename,
                fromStripe: entry.stripe,
                fromPosition: entry.position,
                stripe: destination.stripe,
                position: destination.position,
            });
            kept.push({
                filename: entry.filename,
                stripe: destination.stripe,
                position: destination.position,
            });
        });

        return {
            profile: {perStripe: capacity.perStripe, entries: kept},
            moved: moved,
            overflow: overflow,
            duplicates: duplicates,
            free: free,
        };
    }

    function removeFilename(profile, filename) {
        profile.entries = profile.entries.filter(function (entry) {
            return entry.filename !== filename;
        });
    }

    function updateScreenMapping(mapping, filename, screen, activityId) {
        let found = false;
        for (let index = 0; index + 2 < mapping.length; index += 3) {
            if (mapping[index] === filename && mapping[index + 2] === activityId) {
                mapping[index + 1] = String(screen);
                found = true;
            }
        }
        if (!found) {
            mapping.push(filename, String(screen), activityId);
        }
    }

    function prepareDesktop(desktop, dryRun) {
        desktop.currentConfigGroup = ["General"];
        const raw = desktop.readConfig("changedPositions", "{}");
        const changed = parseJsonObject(raw);
        const count = Object.keys(changed).length;
        if (count > 0 && !dryRun) {
            desktop.writeConfig("changedPositions", "{}");
            desktop.reloadConfig();
        }
        return count;
    }

    function fitDesktops(targetDesktops, dryRun) {
        const states = [];
        targetDesktops.forEach(function (desktop) {
            const geometry = currentDesktopGeometry(desktop);
            const resolution = geometryKey(geometry);
            desktop.currentConfigGroup = ["General"];
            const positionMaps = parseJsonObject(desktop.readConfig("positions", "{}"));
            if (!Object.prototype.hasOwnProperty.call(positionMaps, resolution)) {
                throw new Error("desktop " + desktop.id + " has no profile for " + resolution);
            }
            const original = parsePositionProfile(positionMaps[resolution]);
            const capacity = gridCapacity(desktop, geometry, original.perStripe);
            const result = reconcileProfile(original, capacity);
            desktop.currentConfigGroup = [];
            const activityId = String(desktop.readConfig("activityId", ""));
            if (activityId.length === 0) {
                throw new Error("desktop " + desktop.id + " has no activity id");
            }
            states.push({
                desktop: desktop,
                geometry: geometry,
                resolution: resolution,
                positionMaps: positionMaps,
                capacity: capacity,
                result: result,
                activityId: activityId,
            });
        });

        const screenConfig = ConfigFile("plasma-org.kde.plasma.desktop-appletsrc");
        screenConfig.group = "ScreenMapping";
        const screenMapping = parseKConfigList(screenConfig.readEntry("screenMapping", ""));
        if (screenMapping.length > 0 && screenMapping.length % 3 !== 0) {
            throw new Error("invalid Plasma screen mapping");
        }
        let crossScreenMoves = 0;

        states.forEach(function (source) {
            const remainingOverflow = [];
            source.result.overflow.forEach(function (entry) {
                let destination = null;
                states.forEach(function (candidate) {
                    if (candidate !== source && candidate.result.free.length > 0
                        && (destination === null || candidate.result.free.length > destination.result.free.length)) {
                        destination = candidate;
                    }
                });
                if (destination === null) {
                    remainingOverflow.push(entry);
                    return;
                }

                const slot = destination.result.free.shift();
                removeFilename(source.result.profile, entry.filename);
                removeFilename(destination.result.profile, entry.filename);
                destination.result.profile.entries.push({
                    filename: entry.filename,
                    stripe: slot.stripe,
                    position: slot.position,
                });
                updateScreenMapping(screenMapping, entry.filename, destination.desktop.screen, destination.activityId);
                source.result.moved.push({
                    filename: entry.filename,
                    fromStripe: entry.stripe,
                    fromPosition: entry.position,
                    targetDesktop: destination.desktop.id,
                    stripe: slot.stripe,
                    position: slot.position,
                });
                crossScreenMoves++;
            });
            source.result.overflow = remainingOverflow;
        });

        let unresolved = 0;
        states.forEach(function (state) {
            unresolved += state.result.overflow.length;
            state.positionMaps[state.resolution] = serializePositionProfile(state.result.profile);
        });
        if (unresolved > 0) {
            throw new Error(unresolved + " icons do not fit across the active built-in displays");
        }

        if (!dryRun) {
            states.forEach(function (state) {
                state.desktop.currentConfigGroup = ["General"];
                state.desktop.writeConfig("positions", JSON.stringify(state.positionMaps));
            });
            if (crossScreenMoves > 0) {
                screenConfig.writeEntry("screenMapping", screenMapping);
            }
            states.forEach(function (state) {
                state.desktop.reloadConfig();
            });
        }

        return states.map(function (state) {
            return {
                desktop: state.desktop.id,
                screen: state.desktop.screen,
                resolution: state.resolution,
                slots: state.capacity.slots,
                icons: state.result.profile.entries.length,
                moved: state.result.moved.length,
                duplicatesRemoved: state.result.duplicates,
            };
        });
    }

    function run(phase, orientation, targetGeometries, dryRun) {
        if (!Array.isArray(targetGeometries) || targetGeometries.length !== 2) {
            throw new Error("exactly two enabled built-in output geometries are required");
        }
        const targetDesktops = desktops().filter(function (desktop) {
            return isTargetDesktop(desktop, targetGeometries);
        });
        if (targetDesktops.length !== 2) {
            return {status: "waiting", desktops: targetDesktops.length};
        }

        if (phase === "prepare") {
            let cleared = 0;
            targetDesktops.forEach(function (desktop) {
                cleared += prepareDesktop(desktop, dryRun);
            });
            return {status: "ok", phase: phase, changedPositionsCleared: cleared, dryRun: dryRun};
        }
        if (phase !== "fit") {
            throw new Error("unsupported icon-layout phase: " + phase);
        }
        if (orientation !== "left-up" && orientation !== "right-up") {
            return {status: "ok", phase: phase, skipped: "landscape", dryRun: dryRun};
        }
        return {status: "ok", phase: phase, layouts: fitDesktops(targetDesktops, dryRun), dryRun: dryRun};
    }

    return {
        parseKConfigList: parseKConfigList,
        parsePositionProfile: parsePositionProfile,
        serializePositionProfile: serializePositionProfile,
        reconcileProfile: reconcileProfile,
        updateScreenMapping: updateScreenMapping,
        run: run,
    };
}());

if (typeof ZENBOOK_LAYOUT_TEST_ONLY === "undefined" || !ZENBOOK_LAYOUT_TEST_ONLY) {
    try {
        const result = ZenbookDuoIconLayout.run(
            ZENBOOK_PHASE,
            ZENBOOK_ORIENTATION,
            ZENBOOK_TARGET_GEOMETRIES,
            Boolean(ZENBOOK_DRY_RUN)
        );
        print("ZENBOOK_RESULT=" + JSON.stringify(result));
    } catch (error) {
        print("ZENBOOK_RESULT=" + JSON.stringify({status: "error", message: String(error)}));
    }
}

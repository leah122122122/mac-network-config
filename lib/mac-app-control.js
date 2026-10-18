// JXA / AppKit. Inspect only bundle identity and PID; no arguments/env/logs.
// Never force-quit or send arbitrary Apple Events.
ObjC.import('AppKit');
function run(argv) {
    if (['status', 'quit'].indexOf(argv[0]) < 0 ||
        (argv[0] === 'status' && argv.length !== 2) ||
        (argv[0] === 'quit' && (argv.length !== 3 || !/^[1-9][0-9]*$/.test(argv[2])))) {
        throw new Error('Invalid operation');
    }
    var action = argv[0], path = argv[1];
    var apps = $.NSWorkspace.sharedWorkspace.runningApplications.js;
    var matches = [];
    for (var i = 0; i < apps.length; i++) {
        var app = apps[i];
        if (ObjC.unwrap(app.bundleIdentifier) !== 'com.openai.codex') continue;
        // A different installed copy must not be closed or mistaken for this test.
        if (ObjC.unwrap(app.bundleURL.path) !== path) {
            throw new Error('Another installation is running');
        }
        matches.push(app);
    }
    if (matches.length > 1) throw new Error('Multiple instances are running');
    if (action === 'status') {
        return matches.map(function (app) { return String(app.processIdentifier); }).join('\n');
    }
    for (var j = 0; j < matches.length; j++) {
        // Check inside the same helper that performs termination, not only
        // before the user spends time reading the confirmation prompt.
        if (String(matches[j].processIdentifier) !== argv[2]) {
            throw new Error('Instance changed before termination');
        }
        if (!matches[j].terminate()) throw new Error('Graceful termination refused');
    }
    return 'requested';
}

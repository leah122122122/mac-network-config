// JXA / AppKit. Inspect only bundle identity and PID; no arguments/env/logs.
// Never force-quit or send arbitrary Apple Events.
ObjC.import('AppKit');
function run(argv) {
    var supported = ['com.openai.codex', 'com.openai.chat'];
    if (argv[0] === 'discover' && argv.length === 1) {
        var paths = [];
        function add(url) {
            try {
                var value = ObjC.unwrap(url.URLByResolvingSymlinksInPath.path);
                if (typeof value === 'string' && value.charAt(0) === '/' &&
                    !/[\r\n]/.test(value) && paths.indexOf(value) < 0) paths.push(value);
            } catch (e) { /* Missing registration/URL is not an application. */ }
        }
        var running = $.NSWorkspace.sharedWorkspace.runningApplications.js;
        for (var r = 0; r < running.length; r++) {
            if (supported.indexOf(ObjC.unwrap(running[r].bundleIdentifier)) >= 0) add(running[r].bundleURL);
        }
        for (var b = 0; b < supported.length; b++) {
            add($.NSWorkspace.sharedWorkspace.URLForApplicationWithBundleIdentifier(supported[b]));
        }
        // Only candidate paths. The shell must verify identity, signing and framework.
        return paths.join('\n');
    }
    if (['status', 'quit'].indexOf(argv[0]) < 0 ||
        (argv[0] === 'status' && argv.length !== 2 && argv.length !== 3) ||
        (argv[0] === 'quit' && ((argv.length !== 3 && argv.length !== 4) || !/^[1-9][0-9]*$/.test(argv[2])))) {
        throw new Error('Invalid operation');
    }
    var action = argv[0], path = argv[1];
    var identifier = argv[action === 'status' ? 2 : 3] || 'com.openai.codex';
    if (supported.indexOf(identifier) < 0) throw new Error('Unsupported bundle identity');
    var apps = $.NSWorkspace.sharedWorkspace.runningApplications.js;
    var matches = [];
    for (var i = 0; i < apps.length; i++) {
        var app = apps[i];
        if (ObjC.unwrap(app.bundleIdentifier) !== identifier) continue;
        // A different installed copy must not be closed or mistaken for this test.
        if (ObjC.unwrap(app.bundleURL.URLByResolvingSymlinksInPath.path) !== path) {
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

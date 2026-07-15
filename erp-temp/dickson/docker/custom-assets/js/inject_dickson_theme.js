// Placeholder Dickson Supplies theme injector.
// The original inject_dickson_theme.js was lost on 2026-07-09 when the
// historical data restore overwrote the sites/assets volume with the real
// backup's (mostly empty) assets content -- it was never captured in any
// backup or build process we have access to. Recreated 2026-07-15 as a
// minimal stand-in so the login page stops referencing a missing file;
// replace with the real script once bare metal is restored, if the
// original can be found there.
(function () {
    document.title = document.title.replace(/^ERPNext/, "Dickson Supplies");
})();

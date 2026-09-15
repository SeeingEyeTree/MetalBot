// replay_parser.mjs — thin wrapper around the `sdfz-demo-parser` library
// (https://www.npmjs.com/package/sdfz-demo-parser, maintained by the Beyond
// All Reason project) that prints one replay's parsed info/statistics as
// JSON on stdout. Used by replay_analysis.py so the Python side never has to
// touch the .sdfz binary format directly.
//
// Invoked as a library call (not the package's own CLI binary) because the
// published CLI script in some versions is missing its shebang line and
// fails with an exec-format/shell-syntax error when run directly or via
// `npx sdfz-demo-parser`. Calling the documented API from our own script
// sidesteps that entirely.
//
// Usage: node replay_parser.mjs <path-to-replay.sdfz>

import { DemoParser } from "sdfz-demo-parser";

const demoPath = process.argv[2];
if (!demoPath) {
    console.error("Usage: node replay_parser.mjs <path-to-replay.sdfz>");
    process.exit(1);
}

const parser = new DemoParser({ skipPackets: true });

try {
    const demo = await parser.parseDemo(demoPath);
    process.stdout.write(JSON.stringify(demo));
} catch (err) {
    console.error(`Failed to parse ${demoPath}: ${err.stack || err}`);
    process.exit(1);
}

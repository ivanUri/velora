#!/usr/bin/env node

const url = process.argv.at(-1);
if (url.endsWith("/slow")) setTimeout(() => {}, 10_000);
else if (url.endsWith("/fail")) process.exitCode = 7;
else process.exitCode = 0;

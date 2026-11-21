# Development backup: rp 1.2.9-lab.12

This branch archives the existing development state and pending local source
and documentation changes. It does not merge into or update existing branches.
It is not a release or a claim of 24/7 readiness.

- Deployable source: [rp.sh](rp.sh).
- Source commit for rp.sh: `29f65ed86fb3e902d420738719abce83067e82c5`.
- Source SHA256: `fd25577753ef68767556130b814f03f765aa0c1b0de03458ec96c343821dd27a`.
- Base development checkpoint: `e453226c0773ed7d17fca905d36aef65a1823f74`.
- [Russian work summary and remaining tests](reports/WORK_SUMMARY_RU.md).
- [Acceptance matrix](reports/ACCEPTANCE.json) and [status](reports/STATUS.md).
- [Sanitized historical results](reports/results/README.md).
- [Unit tests](tests), [laboratory tools](lab), [static checks](tools) and CI.

Raw lab artifacts, packet captures, live host configurations, credentials,
generated installation bundles, caches and original private inputs remain
excluded by .gitignore. Local files are retained. Existing experimental tools
are archived as source; archiving does not execute or approve them.

The operator must confirm machine cleanup before the final clean installation,
three complete acceptance regressions and unchanged six-hour soak. No permission
to merge into main has been given.

# Console blocks and one-use HTTPS delivery: lab.20

Baseline fixtures reproduced ignored generator errors and installer exit 7
being replaced by exit 0 by multipart cleanup. Lab.20 checks generation,
compression, chunking and writes; private staging is cleaned on failure.
Generated multipart blocks preserve the installer/pipeline status and reject
missing parts before execution. Configuration and transport architecture are
unchanged. BLOCK_MAX must now be 1201..999999999 to leave room for the wrapper.

Real local HTTPS tests cover wrong public-key pin (curl 90), wrong token,
successful download, reuse rejection and four concurrent downloads with exactly
one winner. A one-second TTL fixture reproduced a request accepted during the
shutdown grace interval. A monotonic expiration check now rejects that request;
the grace interval only lets already accepted transfers finish. Test TTL is a
service argument; production default remains 1800 seconds.

All seven new tests pass locally and on Rocky 10.2. Installer payloads in these
fixtures only create a temporary marker and exit; they do not install services.
The entire suite passes 173 tests and static checks. This evidence does not
substitute for the final real block/link installation and firewall cleanup test.

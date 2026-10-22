# Public references and licenses


1. **Stats — MIT, Copyright (c) 2019 Serhiy Mytrovtsiy**.
   - SMC protocol, mode-key discovery, ARM automatic reset: <https://github.com/exelban/stats/blob/master/SMC/smc.swift> (observed blob `a4d9e473eb7b99e6562ff1ae855fb7f3ea1c62ed`).
   - M5 sensors and common ARM labels: <https://github.com/exelban/stats/blob/master/Modules/Sensors/values.swift#L487> (observed blob `88a6a27e6e326ef34ca824f43ad686a550f63d03`).
   - License: <https://github.com/exelban/stats/blob/master/LICENSE>.
2. **macos-smc-fan research — MIT, Copyright (c) 2026 Alexander Goodkind**.
   - <https://github.com/agoodkind/macos-smc-fan/blob/main/docs/research.md> (observed blob `69d7083e1a1daeee18d061c5033cdac40d13a1c1`). Its M5 physical test was Mac17,7 / macOS 26.4.1, which is distinct from this Mac17,8 host. Its evidence-limit table is important: mode-0 ramping and firmware fallback are not established guarantees.
   - License: <https://github.com/agoodkind/macos-smc-fan/blob/main/LICENSE.md>. This licenses the author's original code/research, not Apple's firmware or binaries.
3. **Apple official ServiceManagement documentation** (API documentation, not MIT source):
   - <https://developer.apple.com/documentation/servicemanagement/smappservice>
   - <https://developer.apple.com/documentation/servicemanagement/smappservice/daemon(plistname:)>
   - <https://developer.apple.com/documentation/servicemanagement/smappservice/register()>

The protocol implementation is independently written from the documented layout and our read-only probe. The sensor table and behavioral references are attributed above. Include the following notices with a redistributed app/source if retaining these contributions.

### MIT notices

Copyright (c) 2019 Serhiy Mytrovtsiy

Copyright (c) 2026 Alexander Goodkind <alex@goodkind.io>

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

<!-- SPDX-License-Identifier: MPL-2.0 -->
<!-- Copyright (c) 2025-2026 awesomo4000 -->

# Third-Party Notices

Turf includes Microsoft WebView2 loader binaries in the following directories:

- `src/platforms/windows/lib/windows-aarch64/`
- `src/platforms/windows/lib/windows-x86/`
- `src/platforms/windows/lib/windows-x86_64/`

These `WebView2Loader.dll` and `WebView2Loader.lib` files are version
`1.0.3351.48` Microsoft components distributed with the Microsoft Edge
WebView2 SDK. They are licensed under the BSD 3-Clause license reproduced in
[`src/platforms/windows/lib/LICENSE-WebView2`](src/platforms/windows/lib/LICENSE-WebView2)
and are not covered by Turf's MPL-2.0 license.

Microsoft's WebView2 deployment documentation describes shipping the
architecture-specific loader with applications:

<https://learn.microsoft.com/en-us/microsoft-edge/webview2/concepts/distribution#files-to-ship-with-the-app>

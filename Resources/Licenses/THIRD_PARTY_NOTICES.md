# Third-Party Notices

OpenNOW redistributes, bundles, and statically links the third-party components listed below. Each
is redistributed under its own license. The full license text for every component appears either in
the appendix of this file or alongside the component in the source tree.

This file ships inside the application bundle at
`OpenNOW.app/Contents/Resources/Resources/Licenses/THIRD_PARTY_NOTICES.md`, so the required notices
accompany the distributed binary rather than living only in the source repository.

Nothing in this file grants rights beyond those in the referenced licenses. The OpenNOW project's
own source is licensed separately under the MIT License (`LICENSE` in the source repository).

## Components

| Component | Version | License | How it reaches the user |
| --- | --- | --- | --- |
| Hanken Grotesk | 3.013, static instances | SIL OFL 1.1 | `Resources/Fonts/*.woff2`, bundled |
| OpenSSL | 3.5.8 | Apache-2.0 | `Vendor/OpenSSL.xcframework`, committed (static) |
| usrsctp | 0.9.5.0 | BSD 3-Clause | `Vendor/usrsctp.xcframework`, committed (static) |
| ably-js | 2.28.0 | Apache-2.0 | `Resources/RemoteCoOp/browser/vendor/ably.min.js`, bundled |
| ably-cocoa | 1.3.0 | Apache-2.0 | statically linked |
| SocketRocket | vendored inside ably-cocoa | BSD (Facebook) | statically linked via Ably |
| delta-codec-cocoa | 1.3.5 | Apache-2.0 | statically linked via Ably |
| xdelta3 | vendored inside delta-codec-cocoa | Apache-2.0 | statically linked via Ably |
| cpp-btree | vendored inside delta-codec-cocoa | Apache-2.0 | statically linked via Ably |
| msgpack-objective-C | 0.4.0 | Apache-2.0 | statically linked via Ably |
| sentry-cocoa | 9.18.0 | MIT, plus bundled third-party | `Sentry.framework`, bundled |
| SwiftLintPlugins | 0.65.1 | MIT | build-time command plugin only; never ships |

None of these components distributes a `NOTICE` file, so there is no Apache-2.0 §4(d) attribution
text to pass through.

## Fonts

### Hanken Grotesk

- Copyright 2021 The Hanken Grotesk Project Authors
  (<https://github.com/marcologous/hanken-grotesk>)
- License: SIL Open Font License 1.1 (<https://scripts.sil.org/OFL>)
- Bundled as WOFF2 in `Resources/Fonts/` (Regular, Medium, Bold static instances of version 3.013).
- Full license text: `Resources/Fonts/OFL.txt`, which ships in the application bundle alongside the
  font files.

The bundled WOFF2 files are static instances generated from the upstream variable font. The OFL's
Reserved Font Name restriction is not triggered: the bundled `OFL.txt` declares no Reserved Font
Name for this family.

## OpenSSL and usrsctp

The native NVST bundle (milestone 4) terminates DTLS/SRTP and SCTP itself instead of relying on
libwebrtc's peer connection. Both libraries ship as **static** frameworks, so they are linked into
the app binary: nothing is embedded at runtime and nothing outside the main binary needs signing.

- OpenSSL 3.5.8 — Apache License 2.0 (appendix below). Provides the DTLS 1.2 client and the SRTP
  keying material export.
- usrsctp 0.9.5.0 — BSD 3-Clause (see the BSD 3-Clause license text below). Provides the SCTP
  data channels that carry NVST control and input.

Neither ships a `NOTICE` file; OpenSSL's `LICENSE.txt` is the Apache-2.0 text reproduced in the
appendix, and usrsctp's `COPYING` is the BSD 3-Clause text reproduced there.

### OpenSSL and usrsctp build provenance

Both are prebuilt binaries committed to this repository; building OpenNOW does not rebuild them.
Derivation:

- OpenSSL: release tarball `openssl-3.5.8.tar.gz` from tag `openssl-3.5.8`
  (<https://github.com/openssl/openssl/releases/tag/openssl-3.5.8>), SHA-256
  `a8f84a39918ec6415ce765d9b429d313ba97b8143169c172e734b9514464f5b2`. Configured and built for
  macOS arm64 only:

  ```
  ./Configure darwin64-arm64-cc no-shared no-tests no-apps no-module no-engine \
      --prefix=<staging> -mmacosx-version-min=15.0 -isysroot <macOS SDK>
  ```

  `libssl.a` and `libcrypto.a` are combined into the single framework binary so one `LibraryPath`
  covers both; `libssl.a` alone would leave `libcrypto` symbols undefined.
- usrsctp: tag `0.9.5.0`, commit `07f871bda23943c43c9e74cc54f25130459de830`
  (<https://github.com/sctplab/usrsctp>). Built with its canonical CMake configuration (3.31.6),
  the Xcode generator and Xcode 27, for macOS 15+ arm64. Reproduce from a clean pinned checkout:

  ```
  CMAKE=/path/to/cmake bash scripts/build-usrsctp.sh /path/to/usrsctp
  ```

  The configuration detects `HAVE_SA_LEN`, `HAVE_SIN_LEN`, `HAVE_SIN6_LEN` and `HAVE_SCONN_LEN`.
  These must not be omitted: the initial hand-compiled archive lacked them and its internal
  `sockaddr_conn` layout disagreed with the public macOS header, breaking `AF_CONN` bind/input.
  IPv4/IPv6 remain enabled; examples, shared libraries and debug logging are disabled. The pinned
  upstream release needs narrow Xcode 27 warning exclusions for unused-but-set locals, old C
  prototypes and 64-to-32 conversions; other warnings remain errors. It uses its bundled SHA-1
  implementation and does not add an mbedTLS dependency.
- Both are arm64-only, matching the committed OpenSSL and usrsctp slices. Adding x86_64 later means rebuilding
  both for that architecture and extending the xcframework slices.

Shipped framework binaries, SHA-256 (for swap detection):

- `Vendor/OpenSSL.xcframework/macos-arm64/OpenSSL.framework/OpenSSL` (static archive, 9.8 MB):
  `fe4c44108bebc87fd25bd90b7482c9fa07b0397d6d792d63101bc70e2eeac5b9`
- `Vendor/usrsctp.xcframework/macos-arm64/usrsctp.framework/usrsctp` (static archive, 600,464 bytes):
  `f6b79358866b2bbbc9e77a46a6ba0fdf6bd361fe07d8e69636d2d1506bb375e0`

Any future update must pick a tagged release, rebuild the same way, and record the new pins and
SHA-256 values here. Consumers: the SwiftPM `OpenNOW` and test targets declare both as binary
targets; the Xcode app and test targets link them. OpenSSL's own headers `#include <openssl/...>`
as a subdirectory, so the directory *containing* `openssl/` is on the header search path in both
build systems — a framework search path alone is not enough.

## Ably

### Ably JavaScript SDK (vendored for Remote Co-Op)

- Version 2.28.0 (`Resources/RemoteCoOp/browser/vendor/ably.min.js`)
- License: Apache License 2.0 (<https://www.apache.org/licenses/LICENSE-2.0>)
- The file carries its own `@license` header naming Ably Real-time Ltd and the Apache Licence v2.0,
  and ships in the application bundle with `Resources/RemoteCoOp/browser/vendor/README.md`, which
  records the version and SHA-256 of what was fetched.
- Full license text: appendix below.

### ably-cocoa

- Swift Package Manager dependency, pinned exactly to `1.3.0`
- License: Apache License 2.0
- Statically linked into the OpenNOW executable.
- Full license text: appendix below.

### SocketRocket

- Vendored inside ably-cocoa at `Source/SocketRocket`
- Copyright (c) 2016-present, Facebook, Inc. All rights reserved.
- License: BSD License (3-clause)
- Statically linked into the OpenNOW executable via Ably.
- Full license text: appendix below.

### delta-codec-cocoa, xdelta3, cpp-btree

- delta-codec-cocoa `1.3.5`, a transitive dependency of ably-cocoa
- xdelta3 and cpp-btree are vendored inside delta-codec-cocoa
- License: Apache License 2.0 for all three
- Statically linked into the OpenNOW executable via Ably.
- Full license text: appendix below.

### msgpack-objective-C

- Version `0.4.0`, a transitive dependency of ably-cocoa
- License: Apache License 2.0
- Statically linked into the OpenNOW executable via Ably.
- Full license text: appendix below.

## Sentry

### sentry-cocoa

- Copyright (c) 2015 Sentry
- Swift Package Manager dependency, pinned exactly to `9.18.0`
- License: MIT License
- Bundled as `Sentry.framework` in the application bundle. The framework itself carries no license
  file, so the required notice is reproduced in the appendix below.

`sentry-cocoa` also statically links third-party code of its own, including SentryCrash (a modified
KSCrash, MIT, © 2012 Karl Stenerud), `__cxa_throw` swapping code derived from work by YANDEX LLC
(MIT, © 2019), facebook/fishhook (BSD 3-Clause), and Apple-originated code under the Apple Public
Source License 2.0. Those notices are maintained upstream and are reproduced verbatim in
`Resources/Licenses/sentry-cocoa-notices.md`, which ships in the application bundle alongside this
file.

## Build and development tooling

### SwiftLintPlugins (SimplyDanny/SwiftLintPlugins)

- Swift Package Manager dependency, wired as a command plugin only; never ships in the distributed
  application.
- License: MIT License

## Trademarks

OpenNOW is an independent community project. It is not affiliated with, endorsed by, or sponsored by
NVIDIA Corporation.

NVIDIA and GeForce NOW are trademarks of NVIDIA Corporation. Valve, Steam, and Steam Controller are
trademarks of Valve Corporation. Xbox is a trademark of Microsoft Corporation. Ubisoft and Ubisoft
Connect are trademarks of Ubisoft Entertainment. Epic and Epic Games Store are trademarks of Epic
Games, Inc. Battle.net and Blizzard are trademarks of Blizzard Entertainment. Gaijin is a trademark
of Gaijin Entertainment. Twitch is a trademark of Twitch Interactive, Inc. Ably is a trademark of
Ably Real-time Ltd. Sentry is a trademark of Functional Software, Inc.

All trademarks are the property of their respective owners and are used for identification purposes
only. Storefront icons in the account-connection settings are fetched at runtime from URLs returned
by the GeForce NOW service. OpenNOW bundles no storefront logos; when a storefront icon has not yet
loaded or is unavailable, a neutral text monogram of the storefront name is shown in its place. None
of this implies endorsement by any of the above.

Use of OpenNOW requires your own GeForce NOW account and compliance with the GeForce NOW Terms of
Use.

## Appendix: license texts

### Apache License 2.0

Applies to: ably-js, ably-cocoa, delta-codec-cocoa, xdelta3, cpp-btree, msgpack-objective-C.

~~~
                                 Apache License
                           Version 2.0, January 2004
                        http://www.apache.org/licenses/

   TERMS AND CONDITIONS FOR USE, REPRODUCTION, AND DISTRIBUTION

   1. Definitions.

      "License" shall mean the terms and conditions for use, reproduction,
      and distribution as defined by Sections 1 through 9 of this document.

      "Licensor" shall mean the copyright owner or entity authorized by
      the copyright owner that is granting the License.

      "Legal Entity" shall mean the union of the acting entity and all
      other entities that control, are controlled by, or are under common
      control with that entity. For the purposes of this definition,
      "control" means (i) the power, direct or indirect, to cause the
      direction or management of such entity, whether by contract or
      otherwise, or (ii) ownership of fifty percent (50%) or more of the
      outstanding shares, or (iii) beneficial ownership of such entity.

      "You" (or "Your") shall mean an individual or Legal Entity
      exercising permissions granted by this License.

      "Source" form shall mean the preferred form for making modifications,
      including but not limited to software source code, documentation
      source, and configuration files.

      "Object" form shall mean any form resulting from mechanical
      transformation or translation of a Source form, including but
      not limited to compiled object code, generated documentation,
      and conversions to other media types.

      "Work" shall mean the work of authorship, whether in Source or
      Object form, made available under the License, as indicated by a
      copyright notice that is included in or attached to the work
      (an example is provided in the Appendix below).

      "Derivative Works" shall mean any work, whether in Source or Object
      form, that is based on (or derived from) the Work and for which the
      editorial revisions, annotations, elaborations, or other modifications
      represent, as a whole, an original work of authorship. For the purposes
      of this License, Derivative Works shall not include works that remain
      separable from, or merely link (or bind by name) to the interfaces of,
      the Work and Derivative Works thereof.

      "Contribution" shall mean any work of authorship, including
      the original version of the Work and any modifications or additions
      to that Work or Derivative Works thereof, that is intentionally
      submitted to Licensor for inclusion in the Work by the copyright owner
      or by an individual or Legal Entity authorized to submit on behalf of
      the copyright owner. For the purposes of this definition, "submitted"
      means any form of electronic, verbal, or written communication sent
      to the Licensor or its representatives, including but not limited to
      communication on electronic mailing lists, source code control systems,
      and issue tracking systems that are managed by, or on behalf of, the
      Licensor for the purpose of discussing and improving the Work, but
      excluding communication that is conspicuously marked or otherwise
      designated in writing by the copyright owner as "Not a Contribution."

      "Contributor" shall mean Licensor and any individual or Legal Entity
      on behalf of whom a Contribution has been received by Licensor and
      subsequently incorporated within the Work.

   2. Grant of Copyright License. Subject to the terms and conditions of
      this License, each Contributor hereby grants to You a perpetual,
      worldwide, non-exclusive, no-charge, royalty-free, irrevocable
      copyright license to reproduce, prepare Derivative Works of,
      publicly display, publicly perform, sublicense, and distribute the
      Work and such Derivative Works in Source or Object form.

   3. Grant of Patent License. Subject to the terms and conditions of
      this License, each Contributor hereby grants to You a perpetual,
      worldwide, non-exclusive, no-charge, royalty-free, irrevocable
      (except as stated in this section) patent license to make, have made,
      use, offer to sell, sell, import, and otherwise transfer the Work,
      where such license applies only to those patent claims licensable
      by such Contributor that are necessarily infringed by their
      Contribution(s) alone or by combination of their Contribution(s)
      with the Work to which such Contribution(s) was submitted. If You
      institute patent litigation against any entity (including a
      cross-claim or counterclaim in a lawsuit) alleging that the Work
      or a Contribution incorporated within the Work constitutes direct
      or contributory patent infringement, then any patent licenses
      granted to You under this License for that Work shall terminate
      as of the date such litigation is filed.

   4. Redistribution. You may reproduce and distribute copies of the
      Work or Derivative Works thereof in any medium, with or without
      modifications, and in Source or Object form, provided that You
      meet the following conditions:

      (a) You must give any other recipients of the Work or
          Derivative Works a copy of this License; and

      (b) You must cause any modified files to carry prominent notices
          stating that You changed the files; and

      (c) You must retain, in the Source form of any Derivative Works
          that You distribute, all copyright, patent, trademark, and
          attribution notices from the Source form of the Work,
          excluding those notices that do not pertain to any part of
          the Derivative Works; and

      (d) If the Work includes a "NOTICE" text file as part of its
          distribution, then any Derivative Works that You distribute must
          include a readable copy of the attribution notices contained
          within such NOTICE file, excluding those notices that do not
          pertain to any part of the Derivative Works, in at least one
          of the following places: within a NOTICE text file distributed
          as part of the Derivative Works; within the Source form or
          documentation, if provided along with the Derivative Works; or,
          within a display generated by the Derivative Works, if and
          wherever such third-party notices normally appear. The contents
          of the NOTICE file are for informational purposes only and
          do not modify the License. You may add Your own attribution
          notices within Derivative Works that You distribute, alongside
          or as an addendum to the NOTICE text from the Work, provided
          that such additional attribution notices cannot be construed
          as modifying the License.

      You may add Your own copyright statement to Your modifications and
      may provide additional or different license terms and conditions
      for use, reproduction, or distribution of Your modifications, or
      for any such Derivative Works as a whole, provided Your use,
      reproduction, and distribution of the Work otherwise complies with
      the conditions stated in this License.

   5. Submission of Contributions. Unless You explicitly state otherwise,
      any Contribution intentionally submitted for inclusion in the Work
      by You to the Licensor shall be under the terms and conditions of
      this License, without any additional terms or conditions.
      Notwithstanding the above, nothing herein shall supersede or modify
      the terms of any separate license agreement you may have executed
      with Licensor regarding such Contributions.

   6. Trademarks. This License does not grant permission to use the trade
      names, trademarks, service marks, or product names of the Licensor,
      except as required for reasonable and customary use in describing the
      origin of the Work and reproducing the content of the NOTICE file.

   7. Disclaimer of Warranty. Unless required by applicable law or
      agreed to in writing, Licensor provides the Work (and each
      Contributor provides its Contributions) on an "AS IS" BASIS,
      WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or
      implied, including, without limitation, any warranties or conditions
      of TITLE, NON-INFRINGEMENT, MERCHANTABILITY, or FITNESS FOR A
      PARTICULAR PURPOSE. You are solely responsible for determining the
      appropriateness of using or redistributing the Work and assume any
      risks associated with Your exercise of permissions under this License.

   8. Limitation of Liability. In no event and under no legal theory,
      whether in tort (including negligence), contract, or otherwise,
      unless required by applicable law (such as deliberate and grossly
      negligent acts) or agreed to in writing, shall any Contributor be
      liable to You for damages, including any direct, indirect, special,
      incidental, or consequential damages of any character arising as a
      result of this License or out of the use or inability to use the
      Work (including but not limited to damages for loss of goodwill,
      work stoppage, computer failure or malfunction, or any and all
      other commercial damages or losses), even if such Contributor
      has been advised of the possibility of such damages.

   9. Accepting Warranty or Additional Liability. While redistributing
      the Work or Derivative Works thereof, You may choose to offer,
      and charge a fee for, acceptance of support, warranty, indemnity,
      or other liability obligations and/or rights consistent with this
      License. However, in accepting such obligations, You may act only
      on Your own behalf and on Your sole responsibility, not on behalf
      of any other Contributor, and only if You agree to indemnify,
      defend, and hold each Contributor harmless for any liability
      incurred by, or claims asserted against, such Contributor by reason
      of your accepting any such warranty or additional liability.

   END OF TERMS AND CONDITIONS
~~~

### BSD License — SocketRocket

~~~
BSD License

For SocketRocket software

Copyright (c) 2016-present, Facebook, Inc. All rights reserved.

Redistribution and use in source and binary forms, with or without modification,
are permitted provided that the following conditions are met:

 * Redistributions of source code must retain the above copyright notice, this
   list of conditions and the following disclaimer.

 * Redistributions in binary form must reproduce the above copyright notice,
   this list of conditions and the following disclaimer in the documentation
   and/or other materials provided with the distribution.

 * Neither the name Facebook nor the names of its contributors may be used to
   endorse or promote products derived from this software without specific
   prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR
ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
(INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON
ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
~~~

### MIT License — sentry-cocoa

~~~
The MIT License (MIT)

Copyright (c) 2015 Sentry

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
~~~

For the third-party code Sentry statically links, see `sentry-cocoa-notices.md` in this directory.

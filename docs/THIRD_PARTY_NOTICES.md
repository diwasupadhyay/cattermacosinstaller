# Third-party notices

Catter's own [MIT license](../LICENSE) applies to its original code. It does not replace upstream copyrights or licenses.

| Component | Use | License/source |
| --- | --- | --- |
| idevice | Native iOS transport and desktop developer utility | [MIT text](../Licenses/idevice.txt); [pinned iOS source](https://github.com/jkcoxson/idevice/tree/3854a5df4a5a6dee71ffce4d8befc2ea356a8065); desktop tools v0.1.68 |
| iPASide engine | Desktop Apple authentication, provisioning and installation | [MIT text](../Licenses/iPASide.txt); [source](https://github.com/pwnapplehat/iPASide/tree/6d86605d0e5291e9d3dbd82a4b9aabe2901d2c93) |
| zsign | Desktop IPA signing | [MIT text](../Licenses/zsign.txt); [source](https://github.com/zhlynn/zsign/tree/614caa8d1ca949e260e5746144aa52d27a4b08d6) |
| pymobiledevice3 | Desktop USB access and developer-image preparation | [GPL-3.0 text](../Licenses/pymobiledevice3.txt); [source](https://github.com/doronz88/pymobiledevice3/tree/8e2be44e6a97edaa67a6812a806f24965ad181c9) |
| CPython and Python packages | Bundled desktop runtime and dependencies | Runtime license files and installed package metadata remain in the bundle; exact versions are recorded in `DEPENDENCIES.txt`. |
| Python Build Standalone | Relocatable macOS Python distribution | Release 20261013, Python 3.12.15; [upstream](https://github.com/astral-sh/python-build-standalone). Included license files must remain in the runtime. |
| XcodeGen | CI-only project generation | MIT; [source](https://github.com/yonaskolb/XcodeGen/tree/21ac9944b0ab546a07422dbed86f33dd2ebd76f8). Not bundled in the IPA. |

OpenSSL, Rust crates, anisette and other transitive components retain their own licenses. This table is not a complete transitive license inventory. Review the exact built dependency set before distribution.

## Desktop release obligations

The desktop installer imports and distributes GPL-3.0 `pymobiledevice3` alongside other components. An MIT notice alone is not sufficient for that distribution. Before publishing installer binaries, review the combined distribution's licensing and provide complete corresponding source, modifications, build instructions and required notices under the applicable terms. A version list or repository link alone is not a substitute for that review.

The release checklist keeps this as an explicit publication gate. Retain license files inside packaged runtimes and signing tools; do not remove them as unused documentation.

## Separate applications and original assets

LocalDevVPN is installed separately. Its implementation and branding are not bundled in Catter. Research/reference applications are not presented as Catter dependencies.

The Catter name and cat logo were supplied by the project owner. No commercial reference application's logo or interface assets are included.

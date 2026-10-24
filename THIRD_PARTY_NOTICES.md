# Third-party references

Pastty is an independent clipboard utility. Its initial design references [Maccy](https://github.com/p0deje/Maccy), by Alexey Rodionov and contributors, published under the [MIT license](https://github.com/p0deje/Maccy/blob/2.7.1/LICENSE).

Downloaded Maccy binaries and source excerpts are retained only in the local, Git-ignored `research/` directory. They are not Pastty distribution assets. Pastty's MIT license does not replace licenses attached to third-party code.

Before incorporating third-party implementation code, preserve its exact copyright and license notices here or in the relevant vendored file. Before each public release, inventory the actual Cargo.lock dependencies and include required license notices with the app. The build now generates DEPENDENCY-LICENSES.txt from the locked normal/build dependency graph and bundles original license notices, including SQLite public-domain dedication. Development-only dependencies are excluded.

The clipboard outline in `assets/clipboard-source.svg` was supplied by the project owner. `assets/Pastty.svg` is the editable Pastty app-icon design based on that outline; generated PNG/ICNS assets are built from these project sources.

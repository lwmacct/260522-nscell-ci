# Incus host cache experiment

The Incus VM jobs deliberately install their host packages directly with APT.
An experiment on the GitHub-hosted `ubuntu-26.04` image tested whether an exact
runner filesystem delta could make this setup faster. The cache was keyed by
the hosted image identity, kernel, architecture, package recipe, script, and
baseline package manifest. It was built on one runner, restored and verified on
a fresh runner, and used only after an exact-key hit.

The design worked functionally but made the jobs substantially slower. In run
`35321713132`, APT downloaded 190 MB in 3 seconds and completed the package
install in 18 seconds. The cache compressed the 891 MB filesystem layer to
about 224 MB and downloaded it in 3 seconds, but overlay extraction took 158
seconds on the verification runner and 237 seconds on the VM smoke runner.
Checksum and archive-member validation took only 3 seconds, so they were not
the bottleneck. Earlier run `35320769115` also measured 244 seconds when using
GNU incremental extraction; removing its directory-purge semantics did not
solve the underlying extraction cost.

Caching the downloaded `.deb` files would retain the package installation work
and only replace a download that took 3 seconds in the measured run. A host
filesystem layer also creates ownership, machine-state, and compatibility risks
that the package manager already handles. The cache path was therefore removed.
Revisit this only if direct APT installation becomes a measured bottleneck, and
require an end-to-end fresh-runner benchmark to beat the direct install before
putting an alternative on the production path.

Run `35325781305` validated the restored direct-install path end to end. The
Incus package install took 24.6 seconds, host initialization took 3.0 seconds,
and the complete VM smoke job passed in 1 minute 49 seconds.

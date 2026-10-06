The product was the target worktree's actual fm-spawn.sh, fm-teardown.sh, Herdr backend, real Treehouse, and real Herdr servers.
Herdr 0.7.4 was downloaded and checksum-verified by bin/fm-install-herdr.sh into the disposable worktree directory.
The machine's installed Herdr 0.9.0 was also used with presentation settings absent.
Every lab was named fm-lab-* and provisioned, inspected, and retired through bin/fm-herdr-lab.sh.
XDG_CONFIG_HOME, TMPDIR, Treehouse pools, lab state, and fixture homes were contained in .test-lab inside the worktree.
A worktree-local symlink to the existing default control socket allowed the helper's read-only default-session tripwire; no default-session control operation was performed.
The recorder executed the real Herdr binary from the worktree and normalized relative session-list socket and directory paths to the absolute addresses of the same resources.
The initial attempt refused these relative socket paths; the fixture was corrected and scenarios re-driven.
The recorder did not invent successful responses or replace layout or lifecycle behavior.
The focus test's existing fault injectors forced transport failure and launch abortion while actual workspace mutations and cleanup ran on the real lab server.
The attached viewer used a 40-by-120 terminal before the child read its grid, and the terminal stream was drained and recorded.
sidebar-live.html renders that live terminal stream, with terminal colors retained; browser screenshot capture was unavailable because the computer-use browser inventory was empty.
An initial recording attempt left a nested viewer and stale foreground connection; its exact disposable viewer ownership was reconciled and the helper stopped and retired the lab.
The corrected recorder and the repeated ordering test completed normal helper teardown.
The pre-fix comparison uses the previous commit's test through the concurrent-abort check, against the same target product code, to isolate the fixture-focus correction.
No lint, static-analysis command, complete repository suite, other gate phase, or production credential mutation was run.
The combined test completed its focus and concurrency portion but correctly refused its secondmate home nested inside the code root.
The affected multi-home portion was re-driven with FM_ROOT_OVERRIDE naming a separate disposable code-root sibling whose bin/, docs/, and .agents/ point to the actual worktree source.
The original test left read-only fixture hook directories; final cleanup grants owner write permission only to disposable fixture directories before deleting them.
The multi-home recovery portion passed; its original teardown call still used the enclosing code root and was correctly refused by the secondmate-removal guard.
A focused removal rerun used the same disposable code-root override for both spawn and teardown, proving registry retirement, covered-primary-worker re-grouping, and exact focus.
The removal fixture initially expected its manually seeded home space to disappear; that expectation was corrected because the seeded captain-owned tab is intentionally retained.
The corrected removal rerun passed and every named lab is absent from the final session inventories.
Automatic approval review rejected the shell deletion command because it forbids force-style shell removal; bounded Python cleanup was used instead.
Bounded cleanup completed; .test-lab no longer exists and the tracked worktree remains unchanged.

# Review findings — wt v0.2.0 (from the roborack#1794 review)

No-op PR: this file exists so review comments have a place to live; not intended to merge.
One finding per line below; the full text is in the attached review comments.

1. wt_new has no nesting guard (wt:309)
2. materialization fallback can silently discard the carried dirty diff (wt-setup.sh:158)
3. wt rm retry loop is futile on dependent clones (wt:605)
4. kill_clone_holders matches the whole mountinfo line (wt:287)
5. AcceptEnv WT_SANDBOX is dead weight (wt:691)
6. sftp/scp fail, and the fix is not one line (wt:682)
7. authorized_keys is regenerated without a header (wt:704)
8. src_commit capture vs snapshot window (wt:342)
9. README: document the fork pattern

# InnoRouter AI skill

The canonical skill lives in [innorouter/](innorouter/SKILL.md). API guidance,
references and the remote consumer fixture are maintained with this library.
[innosquad-agent-skills](https://github.com/InnoSquadCorp/innosquad-agent-skills)
packages immutable copies for Codex and Claude Code and owns installed-host AI
evaluations. The skill source commit and validated library revision are independent.

Support is stable **7.0.x** (`>=7.0.0 <7.1.0`). The fixture pins published
**7.0.0** at `33b0da7639105cfa8e6f5acffa3badb91b5e0254`. See the
[support record](innorouter/references/support.json) and [validation](validation.md).
Later patches retain their selected version and require their own consumer checks.

For standalone installation, copy the complete `innorouter` directory to
`.agents/skills/innorouter` (Codex) or `.claude/skills/innorouter` (Claude Code),
comparing any existing destination first. Preserve all supporting files and modes.
Invoke `$innorouter` or `/innorouter`; automatic discovery is also enabled.
The central plugin uses `$innosquad:innorouter` or `/innosquad:innorouter`.

Run `python3 skills/innorouter/scripts/validate_consumer.py --scratch-path
/tmp/innorouter-skill-validation` for an isolated exact-release consumer.
Do not include local build products or credentials in the skill.

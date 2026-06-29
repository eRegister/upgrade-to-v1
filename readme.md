To run this script, just copy and paste this line below in your terminal:

`curl -fsSL https://raw.githubusercontent.com/eRegister/upgrade-to-v1/refs/heads/main/install.sh -o install.sh`

# Refactoring it so that I can maintain it better

install.sh                       # header + load_modules() + main() + main "$@"
lib/
├── core/
│   ├── config.sh                # all defaults / runtime-state vars
│   ├── logging.sh               # setup_colors, log/info/warn/error/success/step, banner
│   ├── traps.sh                 # on_error, cleanup, install_traps
│   ├── prompt.sh                # confirm, confirm_step, prompt_db_password
│   └── cli.sh                   # usage, parse_args, resolve_config, print_config
├── system/
│   ├── platform.sh              # detect_platform
│   ├── privilege.sh             # detect_privilege, as_root
│   └── deps.sh                  # detect_pkg_mgr, pkg_install, ensure_deps
└── upgrade/
    ├── verify.sh                # verify_checksum, verify_gpg, git_clone_or_update
    ├── detect.sh                # read_current_version
    ├── backup.sh                # ensure_dir, take_backup
    ├── migrate.sh               # shutdown_old_stack, fetch_repos, run_restore
    ├── rollback.sh              # rollback
    └── postinstall.sh           # post_verify, next_steps
# ==================================================================================================
# Agent Project Move: Install
# ==================================================================================================
# Plain-install setup, which replaces an existing link only when it dangles.
# ==================================================================================================

const SCRIPT_DIR = (path self .)
const ROOT = ($SCRIPT_DIR | path dirname)
const MINIMUM = { major: 0, minor: 116 }

const TOOLS = [
  { name: "ripgrep", command: "rg" }
  { name: "sqlite", command: "sqlite3" }
  { name: "zstd", command: "zstd" }
]

def os-kind []: nothing -> string {
  match $nu.os-info.name {
    "macos" => "macos"
    "linux" => {
      let id = (
        try {
          open --raw /etc/os-release
          | lines
          | where {|line| $line starts-with "ID=" }
          | first
          | split row "="
          | get 1
          | str trim --char '"'
        } catch { "" }
      )
      match $id {
        "arch" | "manjaro" | "endeavouros" => "arch"
        "debian" | "ubuntu" => "debian"
        "fedora" => "fedora"
        _ => "linux"
      }
    }
    _ => "other"
  }
}

export def install-line [os: string, tools: list<string>]: nothing -> string {
  let packages = (
    $tools
    | each {|tool| if $os == "debian" and $tool == "sqlite" { "sqlite3" } else { $tool } }
  )
  match $os {
    "macos" => $"brew install ($packages | str join ' ')"
    "arch" => $"sudo pacman -S --needed ($packages | str join ' ')"
    "debian" => $"sudo apt install ($packages | str join ' ')"
    "fedora" => $"sudo dnf install ($packages | str join ' ')"
    _ => $"Install ($packages | str join ', ') with your package manager."
  }
}

def gnu-coreutils? []: nothing -> bool {
  let run = (^stat --version | complete)
  ($run.exit_code == 0) and ($run.stdout | str contains "GNU coreutils")
}

def missing-tools []: nothing -> list<string> {
  mut missing: list<string> = []
  for tool in $TOOLS {
    if (which $tool.command | is-empty) {
      $missing = ($missing | append $tool.name)
    }
  }
  if not (gnu-coreutils?) {
    $missing = ($missing | append "coreutils")
  }
  $missing
}

def check-tools []: nothing -> nothing {
  let missing = (missing-tools)
  let current = (version)
  let old = (
    ($current.major < $MINIMUM.major)
    or (($current.major == $MINIMUM.major) and ($current.minor < $MINIMUM.minor))
  )
  let os = (os-kind)
  let package_nushell = ($old and ($os in ["macos" "arch"]))
  let packages = (if $package_nushell { $missing | append "nushell" } else { $missing })
  let problems = (
    [
      (if ($missing | is-not-empty) { $"Missing: ($missing | str join ', ')" })
      (if $old {
        $"Nushell ($current.major).($current.minor) is older than ($MINIMUM.major).($MINIMUM.minor)"
      })
    ]
    | compact
  )
  let lines = (
    [
      (if ($packages | is-not-empty) { install-line $os $packages })
      (if $old and not $package_nushell {
        "Install Nushell from https://www.nushell.sh/book/installation.html"
      })
    ]
    | compact
  )
  if ($problems | is-not-empty) {
    error make --unspanned {
      msg: ($problems | str join ". ")
      help: ($lines | str join (char newline))
    }
  }
}

def link-entry [link: string, target: string]: nothing -> string {
  let kind = ($link | path type | default "")
  if $kind == "symlink" {
    if not ($link | path exists) {
      ^ln -sfn $target $link
      return $"relinked: ($link)"
    }
    if ($link | path expand) == ($target | path expand) {
      return $"already linked: ($link)"
    }
    let current = (^readlink $link | str trim)
    error make --unspanned {
      msg: $"($link) points at ($current)"
      help: "Move that entry aside, then rerun 'agent-project-move setup'."
    }
  }
  if $kind != "" {
    error make --unspanned {
      msg: $"($link) exists and is not a link"
      help: "Move that entry aside, then rerun 'agent-project-move setup'."
    }
  }
  mkdir ($link | path dirname)
  ^ln -s $target $link
  $"linked: ($link)"
}

export def setup []: nothing -> nothing {
  check-tools

  let launcher = ($ROOT | path join bin agent-project-move)
  if not ($launcher | path exists) {
    error make --unspanned {
      msg: "setup runs from a clone, with bin/agent-project-move beside src/"
      help: "Clone the repository, then run its bin/agent-project-move setup."
    }
  }

  let local_bin = ($env.HOME | path join .local bin)
  print (link-entry ($local_bin | path join agent-project-move) $launcher)
  if not (
    $env.PATH | any {|entry| ($entry | path expand) == ($local_bin | path expand) }
  ) {
    print $"Add ($local_bin) to PATH: export PATH=\"($local_bin):$PATH\""
  }

  let skill = ($ROOT | path join skills agent-project-move)
  let claude_link = ($env.HOME | path join .claude skills agent-project-move)
  print (link-entry $claude_link $skill)
  let configured = ($env.CLAUDE_CONFIG_DIR? | default "")
  if $configured != "" and (
    ($configured | path expand) != (($env.HOME | path join .claude) | path expand)
  ) {
    print (link-entry ($configured | path join skills agent-project-move) $skill)
  }
  let codex_home = ($env.CODEX_HOME? | default ($env.HOME | path join .codex))
  print (link-entry ($codex_home | path join skills agent-project-move) $skill)
}

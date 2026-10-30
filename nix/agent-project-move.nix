# ==================================================================================================
# agent-project-move
# ==================================================================================================

{
  lib,
  coreutils,
  diffutils,
  findutils,
  makeBinaryWrapper,
  nushell,
  ripgrep,
  sqlite,
  stdenvNoCC,
  zstd,
}:

stdenvNoCC.mkDerivation {
  pname = "agent-project-move";
  version = "0.1.0";

  src = lib.fileset.toSource {
    root = ../src;
    fileset = lib.fileset.difference (lib.fileset.fileFilter (file: file.hasExt "nu") ../src) (
      lib.fileset.fileFilter (file: lib.hasSuffix ".test.nu" file.name) ../src
    );
  };

  nativeBuildInputs = [ makeBinaryWrapper ];

  dontBuild = true;

  installPhase = ''
    mkdir -p $out/share/agent-project-move
    cp -r --no-preserve=mode . $out/share/agent-project-move
    # Nushell names `main` in --help after the script file.
    mv $out/share/agent-project-move/agent-project-move.nu \
      $out/share/agent-project-move/agent-project-move

    mkdir -p $out/share/skills
    cp -r --no-preserve=mode ${../skills/agent-project-move} \
      $out/share/skills/agent-project-move

    makeWrapper ${lib.getExe nushell} $out/bin/agent-project-move \
      --add-flags "--no-config-file $out/share/agent-project-move/agent-project-move" \
      --prefix PATH : ${
        lib.makeBinPath [
          coreutils
          diffutils
          findutils
          ripgrep
          sqlite
          zstd
        ]
      }
  '';

  meta = {
    description = "Move, prune, and transfer the project state stored by coding agents";
    homepage = "https://github.com/hakula139/agent-project-move";
    license = lib.licenses.mit;
    mainProgram = "agent-project-move";
    platforms = lib.platforms.all;
  };
}

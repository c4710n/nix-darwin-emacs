self: super:
let
  mkGitEmacs = namePrefix: jsonFile: { ... }@args:
    let
      repoMeta = super.lib.importJSON jsonFile;
      fetcher =
        if repoMeta.type == "savannah" then
          super.fetchFromSavannah
        else if repoMeta.type == "github" then
          super.fetchFromGitHub
        else
          throw "Unknown repository type ${repoMeta.type}!";
    in
    builtins.foldl'
      (drv: fn: fn drv)
      super.emacs
      ([

        (drv: drv.override ({ srcRepo = true; } // args))

        (
          drv: drv.overrideAttrs (
            old: {
              name = "${namePrefix}-${repoMeta.version}";
              inherit (repoMeta) version;
              src = fetcher (builtins.removeAttrs repoMeta [ "type" "version" ]);

              patches = [
                ./patches/no-frame-refocus-cocoa.patch

                # GNU Emacs's main role is an AXTextField instead of AXWindow, it has to be fixed manually.
                # The patches is borrowed from https://github.com/d12frosted/homebrew-emacs-plus/blob/f3c16d68bbf52c1779be279579d124d726f0d04a/patches/emacs-28/
                ./patches/fix-window-role.patch

                ./patches/system-appearance.patch
                ./patches/poll.patch
                ./patches/round-undecorated-frame.patch
              ];

              postInstall = old.postInstall + ''
                cp ${./icons/memeplex-wide.icns} $out/Applications/Emacs.app/Contents/Resources/Emacs.icns
              '';

              postPatch = old.postPatch + ''
                substituteInPlace lisp/loadup.el \
                --replace '(emacs-repository-get-version)' '"${repoMeta.rev}"' \
                --replace '(emacs-repository-get-branch)' '"master"'
              '' +
                # XXX: remove when https://github.com/NixOS/nixpkgs/pull/193621 is merged
                (super.lib.optionalString (old ? NATIVE_FULL_AOT)
                  (
                    let
                      backendPath = (super.lib.concatStringsSep " "
                        (builtins.map (x: ''\"-B${x}\"'') [
                          # Paths necessary so the JIT compiler finds its libraries:
                          "${super.lib.getLib self.libgccjit}/lib"
                          "${super.lib.getLib self.libgccjit}/lib/gcc"
                          "${super.lib.getLib self.stdenv.cc.libc}/lib"

                          # Executable paths necessary for compilation (ld, as):
                          "${super.lib.getBin self.stdenv.cc.cc}/bin"
                          "${super.lib.getBin self.stdenv.cc.bintools}/bin"
                          "${super.lib.getBin self.stdenv.cc.bintools.bintools}/bin"
                        ]));
                    in
                    ''
                                              substituteInPlace lisp/emacs-lisp/comp.el --replace \
                                                  "(defcustom comp-libgccjit-reproducer nil" \
                                                  "(setq native-comp-driver-options '(${backendPath}))
                      (defcustom comp-libgccjit-reproducer nil"
                    ''
                  ));
            }
          )
        )

        # reconnect pkgs to the built emacs
        (
          drv:
          let
            result = drv.overrideAttrs (old: {
              passthru = old.passthru // {
                pkgs = self.emacsPackagesFor result;
              };
            });
          in
          result
        )

        (
          drv: drv.overrideAttrs (old:
            let
              libName = drv: super.lib.removeSuffix "-grammar" drv.pname;
              lib = drv: ''lib${libName drv}.dylib'';
              linkCmd = drv: ''
                cp ${drv}/parser .
                chmod +w ./parser
                install_name_tool -id $out/lib/${lib drv} ./parser
                cp ./parser $out/lib/${lib drv}
                /usr/bin/codesign -s - -f $out/lib/${lib drv}
              '';
              plugins = with self.pkgs.tree-sitter-grammars; [
                tree-sitter-bash
                tree-sitter-c
                tree-sitter-c-sharp
                tree-sitter-cmake
                tree-sitter-cpp
                tree-sitter-css
                tree-sitter-dockerfile
                tree-sitter-go
                tree-sitter-gomod
                tree-sitter-java
                tree-sitter-python
                tree-sitter-javascript
                tree-sitter-json
                tree-sitter-rust
                tree-sitter-toml
                tree-sitter-tsx
                tree-sitter-typescript
                tree-sitter-yaml
                tree-sitter-elixir
                tree-sitter-heex
                tree-sitter-eex
              ];
              tree-sitter-grammars = super.runCommandCC "tree-sitter-grammars" { }
                (super.lib.concatStringsSep "\n" ([ "mkdir -p $out/lib" ] ++ (map linkCmd plugins)));
            in
            {
              buildInputs = old.buildInputs ++ [ self.pkgs.tree-sitter tree-sitter-grammars ];
              TREE_SITTER_LIBS = "-ltree-sitter";
              # Add to list of directories dlopen/dynlib_open searches for tree sitter languages *.dylib.
              postFixup = old.postFixup + ''
                install_name_tool -add_rpath ${super.lib.makeLibraryPath [ tree-sitter-grammars ]} $out/bin/emacs
                /usr/bin/codesign -s - -f $out/bin/emacs
              '';
            }
          )
        )
      ]);
in
{
  emacsGit = mkGitEmacs "emacs-git" ../repos/emacs/emacs-master.json {
    withSQLite3 = true;
    withWebP = true;
  };

  emacsWithPackagesFromUsePackage = import ../elisp.nix { pkgs = self; };

  emacsWithPackagesFromPackageRequires = import ../packreq.nix { pkgs = self; };

}

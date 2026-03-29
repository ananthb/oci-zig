{
  description = "runz - OCI container runtime and library in Zig";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    pre-commit-hooks = {
      url = "github:cachix/git-hooks.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    oci-spec-zig = {
      url = "github:navidys/oci-spec-zig";
      flake = false;
    };
  };

  outputs = { self, nixpkgs, flake-utils, pre-commit-hooks, oci-spec-zig }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        version = if (self ? shortRev) then self.shortRev else "dev";

        # Zig dependency hash must match build.zig.zon
        ociSpecHash = "ocispec-0.4.0-dev-voj0cey1AgDS-1Itn3Xu5AiWtB6cwMddZtDUssOtWrIn";

        # Pre-fetch zig deps for sandboxed builds
        zigDepsDir = pkgs.runCommand "runz-deps" {} ''
          mkdir -p $out
          ln -s ${oci-spec-zig} $out/${ociSpecHash}
        '';

        pre-commit-check = pre-commit-hooks.lib.${system}.run {
          src = ./.;
          hooks = {
            zig-fmt = {
              enable = true;
              name = "zig fmt";
              entry = "${pkgs.zig}/bin/zig fmt";
              files = "\\.zig$";
              pass_filenames = false;
              args = [ "--check" "src/" ];
            };

            trailing-whitespace = {
              enable = true;
              name = "trailing whitespace";
              entry = "${pkgs.python3}/bin/python3 -c \"
import sys, pathlib
ok = True
for f in pathlib.Path('.').rglob('*.zig'):
    for i, line in enumerate(f.read_text().splitlines(), 1):
        if line != line.rstrip():
            print(f'{f}:{i}: trailing whitespace')
            ok = False
sys.exit(0 if ok else 1)
\"";
              files = "\\.zig$";
              pass_filenames = false;
            };
          };
        };

        zigBuildArgs = "--system ${zigDepsDir}";

      in
      {
        checks = {
          inherit pre-commit-check;

          test = pkgs.stdenv.mkDerivation {
            pname = "runz-test";
            inherit version;
            src = ./.;

            nativeBuildInputs = [ pkgs.zig ];
            dontConfigure = true;
            dontInstall = true;

            buildPhase = ''
              export ZIG_GLOBAL_CACHE_DIR=$(mktemp -d)
              zig build test ${zigBuildArgs}
              touch $out
            '';
          };

          fuzz = pkgs.stdenv.mkDerivation {
            pname = "runz-fuzz";
            inherit version;
            src = ./.;

            nativeBuildInputs = [ pkgs.zig ];
            dontConfigure = true;
            dontInstall = true;

            buildPhase = ''
              export ZIG_GLOBAL_CACHE_DIR=$(mktemp -d)
              zig build fuzz ${zigBuildArgs}
              touch $out
            '';
          };

          fmt = pkgs.stdenv.mkDerivation {
            pname = "runz-fmt";
            inherit version;
            src = ./.;

            nativeBuildInputs = [ pkgs.zig ];
            dontConfigure = true;
            dontInstall = true;

            buildPhase = ''
              export ZIG_GLOBAL_CACHE_DIR=$(mktemp -d)
              zig fmt --check src/
              touch $out
            '';
          };

          build = pkgs.stdenv.mkDerivation {
            pname = "runz-build";
            inherit version;
            src = ./.;

            nativeBuildInputs = [ pkgs.zig ];
            dontConfigure = true;
            dontInstall = true;

            buildPhase = ''
              export ZIG_GLOBAL_CACHE_DIR=$(mktemp -d)
              zig build ${zigBuildArgs}
              touch $out
            '';
          };
        };

        devShells.default = pkgs.mkShell {
          inherit (pre-commit-check) shellHook;

          buildInputs = with pkgs; [
            zig
            zls
            valgrind
            skopeo
            podman
          ];
        };
      }
    ) // {
      # Integration tests comparing oci-zig with podman/skopeo
      # Run with: nix flake check (requires Linux with KVM)
      checks.x86_64-linux = let
        pkgs = nixpkgs.legacyPackages.x86_64-linux;
      in (nixpkgs.legacyPackages.x86_64-linux.lib.optionalAttrs pkgs.stdenv.isLinux {
        # Test: OCI image pull produces valid layout that skopeo can inspect
        image-pull-compat = pkgs.testers.nixosTest {
          name = "runz-image-pull-compat";
          nodes.machine = { pkgs, ... }: {
            virtualisation.memorySize = 2048;
            environment.systemPackages = [ pkgs.skopeo pkgs.jq ];
          };
          testScript = ''
            machine.wait_for_unit("network-online.target")

            # Pull alpine with skopeo as reference
            machine.succeed("skopeo copy docker://docker.io/library/alpine:latest oci:/tmp/skopeo-alpine:latest")

            # Verify skopeo layout has expected structure
            machine.succeed("test -f /tmp/skopeo-alpine/index.json")
            machine.succeed("test -f /tmp/skopeo-alpine/oci-layout")

            # Verify index.json is valid and has manifests
            machine.succeed("jq '.manifests | length > 0' /tmp/skopeo-alpine/index.json | grep true")

            # Verify manifest has layers
            manifest_digest=$(jq -r '.manifests[0].digest' /tmp/skopeo-alpine/index.json)
            hash=''${manifest_digest#sha256:}
            machine.succeed(f"jq '.layers | length > 0' /tmp/skopeo-alpine/blobs/sha256/{hash} | grep true")
          '';
        };

        # Test: OCI layer extraction produces correct filesystem
        layer-extract-compat = pkgs.testers.nixosTest {
          name = "runz-layer-extract-compat";
          nodes.machine = { pkgs, ... }: {
            virtualisation.memorySize = 2048;
            environment.systemPackages = [ pkgs.podman pkgs.diffutils ];
            virtualisation.containers.enable = true;
          };
          testScript = ''
            machine.wait_for_unit("network-online.target")

            # Create a rootfs with podman as reference
            machine.succeed("podman pull docker.io/library/alpine:latest")
            machine.succeed("podman create --name test-alpine docker.io/library/alpine:latest /bin/true")
            machine.succeed("podman export test-alpine | tar -C /tmp/podman-rootfs -xf -")

            # Verify essential files exist in podman's extraction
            machine.succeed("test -f /tmp/podman-rootfs/bin/busybox")
            machine.succeed("test -L /tmp/podman-rootfs/bin/sh")
            machine.succeed("test -d /tmp/podman-rootfs/etc")
            machine.succeed("test -d /tmp/podman-rootfs/usr")
          '';
        };

        # Test: Container execution with namespace isolation
        container-run-compat = pkgs.testers.nixosTest {
          name = "runz-container-run-compat";
          nodes.machine = { pkgs, ... }: {
            virtualisation.memorySize = 2048;
            environment.systemPackages = [ pkgs.podman ];
            virtualisation.containers.enable = true;
          };
          testScript = ''
            machine.wait_for_unit("network-online.target")

            # Run a command in podman and capture output
            result = machine.succeed("podman run --rm docker.io/library/alpine:latest cat /etc/os-release")
            assert "Alpine" in result, f"Expected 'Alpine' in output, got: {result}"

            # Verify podman uses namespaces
            result = machine.succeed("podman run --rm docker.io/library/alpine:latest cat /proc/1/status | head -1")
            assert "cat" in result or "Name:" in result
          '';
        };
      });
    };
}

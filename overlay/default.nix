# `nixpkgs` here are the `nixpkgs` sources, i.e. the flake input
nixpkgs:

# This might be helfpul later:
# https://www.reddit.com/r/NixOS/comments/6hswg4/how_do_i_turn_an_overlay_into_a_proper_package_set/
self: super:

let
  inherit (super)
    lib
    stdenv
    fetchFromGitHub
    callPackage
    fetchpatch
    buildGoModule
    haskell
    haskellPackages
    ;

  overlayOCamlPackages =
    attrs: import ../ocaml/overlay-ocaml-packages.nix (attrs // { inherit nixpkgs; });
  staticLightExtend =
    pkgSet:
    pkgSet.extend (
      self: super:
      super.lib.overlayOCamlPackages {
        inherit super;
        overlays = [ (super.callPackage ../static/ocaml.nix { }) ];
        updateOCamlPackages = true;
      }
    );

in

(overlayOCamlPackages {
  inherit super;
  overlays = [
    (callPackage ../ocaml {
      inherit nixpkgs;
      super-opaline = super.opaline;
      oniguruma-lib = super.oniguruma;
      libgsl = super.gsl;
    })
  ];
})
// {
  # Cross-compilation / static overlays
  pkgsMusl = staticLightExtend super.pkgsMusl;
  pkgsStatic = staticLightExtend super.pkgsStatic;

  pkgsCross =
    let
      static-overlay = import ../static;
      cross-overlay = callPackage ../cross { };
    in
    super.pkgsCross
    // {
      musl64 = super.pkgsCross.musl64.extend static-overlay;

      aarch64-multiplatform = super.pkgsCross.aarch64-multiplatform.extend cross-overlay;

      aarch64-multiplatform-musl = (
        super.pkgsCross.aarch64-multiplatform-musl.appendOverlays [
          cross-overlay
          static-overlay
        ]
      );

      riscv64 = super.pkgsCross.riscv64.extend cross-overlay;
    };

  # Override `pkgs.nix` to the unstable channel
  nix = super.nixVersions.latest;

  # Other packages

  # Stripped down postgres without the `bin` part, to allow static linking
  # with musl.
  libpq =
    (super.postgresql_16.override {
      systemdSupport = false;
      gssSupport = false;
      openssl = self.openssl-oc;
      lz4 = self.lz4-oc;
      zstd = self.zstd-oc;
    }).overrideAttrs
      (o: {
        doCheck = false;
        configureFlags =
          [
            "--without-ldap"
            "--without-readline"
            "--with-openssl"
            "--with-libxml"
            "--sysconfdir=/etc"
            "--libdir=$(out)/lib"
            "--with-system-tzdata=${super.tzdata}/share/zoneinfo"
            "--enable-debug"
            "--with-icu"
            "--with-lz4"
            "--with-zstd"
            (if stdenv.isDarwin then "--with-uuid=e2fs" else "--with-ossp-uuid")
          ]
          ++ lib.optionals stdenv.hostPlatform.isRiscV [ "--disable-spinlocks" ]
          ++ lib.optionals stdenv.isLinux [ "--with-pam" ];

        buildInputs =
          with self;
          [
            zlib-oc
            libxml2
            icu
            libxcrypt
            lz4
            zstd
          ]
          ++ lib.optionals stdenv.isLinux [ linux-pam ]
          ++ lib.optionals (!stdenv.isDarwin) [ libossp_uuid ];

        propagatedBuildInputs = [ self.openssl-oc.dev ];
        # Use a single output derivation. The upstream PostgreSQL derivation
        # produces multiple outputs (including "out" and "lib"), and then puts some
        # lib/ artifacts in `$lib/lib` and some in `$out/lib`. This causes the
        # pkg-config `--libs` flags to be invalid (since it only knows about one
        # such lib path, not both)
        outputs = [ "out" ];
        postInstall = ''
          # Prevent a retained dependency on gcc-wrapper.
          substituteInPlace "$out/lib/pgxs/src/Makefile.global" --replace-warn ${stdenv.cc}/bin/ld ld
          if [ -z "''${dontDisableStatic:-}" ]; then
            # Remove static libraries in case dynamic are available.
            for i in $out/lib/*.a; do
              name="$(basename "$i")"
              ext="${stdenv.hostPlatform.extensions.sharedLibrary}"
              if [ -e "$out/lib/''${name%.a}$ext" ] || [ -e "''${i%.a}$ext" ]; then
                rm "$i"
              fi
            done
          fi
        '';
      });

  binaryen = super.binaryen.overrideAttrs (_: rec {
    version = "114";
    patches = [ ];

    src = fetchFromGitHub {
      owner = "WebAssembly";
      repo = "binaryen";
      rev = "version_${version}";
      hash = "sha256-bzHNIQy0AN8mIFGG+638p/MBSqlkWuaOzKGSsMDAPH4=";
    };
  });

  opaline = null;
  ott = super.ott.override { opaline = self.ocamlPackages.opaline; };
  esy = callPackage ../ocaml/esy { ocamlPackages = self.ocaml-ng.ocamlPackages_4_14; };

  h2spec = super.buildGoModule {
    pname = "h2spec";
    version = "dev";

    src = fetchFromGitHub {
      owner = "summerwind";
      repo = "h2spec";
      rev = "af83a65f0b";
      sha256 = "sha256-z06uQiImMD4nPLp4Qxka9JT9NTmY0AurnHQKhB/kM40=";
    };
    vendorHash = "sha256-YSaLOYIHgMCK2hXSDL+aoBEfOX7j6rnJ4DMWg0jhzWY=";
  };

  h3spec = haskell.lib.compose.justStaticExecutables (
    haskellPackages.callPackage (
      {
        mkDerivation,
        base,
        bytestring,
        hspec,
        hspec-core,
        http-types,
        http3,
        network,
        quic,
        tls,
        unliftio,
      }:
      mkDerivation rec {
        pname = "h3spec";
        version = "0.1.8";
        src = fetchFromGitHub {
          owner = "kazu-yamamoto";
          repo = "h3spec";
          rev = "b44e487b143a45536206773b06eb2c80cbbae28e";
          sha256 = "sha256-nH4NaxHdnf4kaCCUnJXSkjt5Wkb8qGv3d0+sVjyatXA==";
        };

        isExecutable = true;
        libraryHaskellDepends = [
          base
          bytestring
          hspec
          hspec-core
          http-types
          http3
          network
          quic
          tls
          unliftio
        ];
        executableHaskellDepends = libraryHaskellDepends;
        mainProgram = "h3spec";
        license = lib.licenses.mit;
      }
    ) { }
  );

  hermes = stdenv.mkDerivation {
    name = "hermes";
    src = super.fetchFromGitHub {
      owner = "facebook";
      repo = "hermes";
      rev = "ee2922a50fb719bdb378025d95dbd32ad93cd679";
      hash = "sha256-TXTcKAdfnznJQu2YPCRwzDlKMoV/nvp5mpsIrMUmH1c=";
    };
    patches = [ ./hermes-static-link.patch ];
    buildPhase = ''
      ninjaBuildPhase
    '';
    cmakeFlags = [
      "-GNinja"
      "-DHERMES_ENABLE_TEST_SUITE=false"
    ] ++ lib.optional stdenv.isDarwin [ "-DHERMES_BUILD_APPLE_FRAMEWORK=false" ];
    nativeBuildInputs = with self; [
      cmake
      python3
      ninja
    ];
    propagatedBuildInputs = with self; [
      icu
      readline-oc
    ];
  };

  lib = lib // {
    inherit overlayOCamlPackages;
  };

  inherit (callPackage ../cockroachdb { }) cockroachdb-21_1_x cockroachdb-21_2_x cockroachdb-22_x;
  cockroachdb = self.cockroachdb-21_1_x;

  opam = self.ocamlPackages.opam;

  pnpm =
    let
      inherit (self)
        writeScriptBin
        runtimeShell
        nodejs_latest
        nodePackages_latest
        ;
    in
    writeScriptBin "pnpm" ''
      #!${runtimeShell}
      ${nodejs_latest}/bin/node \
        ${nodePackages_latest.pnpm}/lib/node_modules/pnpm/bin/pnpm.cjs \
        "$@"
    '';

  rdkafka = super.rdkafka.overrideAttrs (_: {
    src = super.fetchFromGitHub {
      owner = "confluentinc";
      repo = "librdkafka";
      rev = "v2.2.0";
      hash = "sha256-v/FjnDg22ZNQHmrUsPvjaCs4UQ/RPAxQdg9i8k6ba/4=";
    };
  });

  melange-relay-compiler =
    let
      inherit (super)
        rustPlatform
        darwin
        pkg-config
        openssl
        ;
      melange-relay-compiler-src = stdenv.mkDerivation {
        name = "melange-relay-compiler-src";
        src = fetchFromGitHub {
          owner = "anmonteiro";
          repo = "relay";
          rev = "75652adf7142bb043eaf11143fffcc557ab8cc68";
          hash = "sha256-Y0tsePP91M6996JROnWHVD9AZqqPQhdATvxC1aV/6ws=";
          sparseCheckout = [ "compiler" ];
        };
        dontBuild = true;
        installPhase = ''
          mkdir $out
          cp -r ./* $out
        '';
      };
    in
    rustPlatform.buildRustPackage {
      pname = "relay";
      version = "n/a";
      src = "${melange-relay-compiler-src}/compiler";
      cargoHash = "sha256-A7rYqZqGiO4X+DH79VWICTpMMDu2uL7LAgaa1+qG3zY=";

      nativeBuildInputs = lib.optionals stdenv.isLinux [ pkg-config ];
      # Needed to get openssl-sys to use pkg-config.
      # Doesn't seem to like OpenSSL 3
      OPENSSL_NO_VENDOR = 1;

      buildInputs = lib.optionals stdenv.isLinux [ openssl ];
      propagatedBuildInputs = lib.optionals stdenv.isDarwin [ darwin.apple_sdk.frameworks.Security ];

      postInstall = ''
        mv $out/bin/relay $out/bin/melange-relay-compiler
        ln -sf $out/bin/melange-relay-compiler $out/bin/melrelay
      '';
      doCheck = false;
      meta = with lib; {
        description = "Melange Relay compiler";
        homepage = "https://github.com/anmonteiro/relay";
        maintainers = [ maintainers.anmonteiro ];
      };
    };
}
// (lib.mapAttrs' (n: p: lib.nameValuePair "${n}-oc" p) {
  inherit (super)
    gmp
    libev
    lz4
    pcre
    rdkafka
    sqlite
    zlib
    zstd
    readline
    ;
  libffi = super.libffi.overrideAttrs (_: {
    doCheck = false;
  });
  openssl = super.openssl_3_0;
})

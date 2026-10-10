# Patcher tool registry — the single place where a cli-source is classified.
#
# The engine (utils.sh/build.sh) sources this file and calls
#   resolve_patcher "<cli-source repo>"
# which infers the tool kind ONCE (the substring rules below are now the only
# such inference in the codebase) and exports PATCHER_* capability flags.
# Every former `[[ "$cli_source_l" == *"npatch"* ]]`-style branch reads the
# flags instead. Adding a new patcher tool = add a case here + set its flags.
#
# Flags exported:
#   PATCHER_KIND          revanced | morphe | xposed | instafel | generic
#   PATCHER_FLOW          cli-patch | xposed-module | instafel-workflow
#   PATCHER_BUNDLE_RE     jq regex matching the tool's patch-bundle assets
#   PATCHER_LIST_BUNDLE_ARG  flag for list-versions/list-patches bundle args
#                            ("--patches" morphe, "-p" revanced/generic, "" else)
#   PATCHER_PATCH_BUNDLE_LONG / PATCHER_PATCH_BUNDLE_SHORT
#                        long/short flags the patch flow uses per bundle
#                        ("--patches"/"-p" for cli-patch flows; "" elsewhere —
#                        xposed modules and instafel have their own arg shapes)
#   PATCHER_LIST_X        "-x" (morphe list commands) or "" (default)
#   PATCHER_LIST_B        "-b" appended to list-versions/list-patches for
#                         revanced-family (" -b" / "")
#   PATCHER_LIST_VERSIONS_SUB / PATCHER_LIST_PATCHES_SUB  subcommand names
#   PATCHER_HAS_PATCH_LIST  false => list output is synthetic; skip app-patch
#                           pre-filter and version-compat checks
#   PATCHER_ANY_VERSION     true  => always considered compatible
#   PATCHER_NEEDS_BKS       true  => the tool asks the JVM for a BKS keystore, so
#                                 the runner needs the BouncyCastle provider
#                                 installed. NPatch only: it calls the
#                                 single-argument KeyStore.getInstance("BKS").
#                                 ReVanced CLI and Morphe want BKS too, but ship
#                                 their own provider, so they need nothing here.
#   PATCHER_SIGNING         true  => patch flow passes keystore flags
#   PATCHER_KEYSTORE_FORMAT bks | pkcs12 - which store format this tool will read
#                                 for its own signing: NPatch loads the file as BKS,
#                                 LSPatch through KeyStore.getDefaultType()
#                                 (PKCS12). patch_apk maps it to RVB_KEYSTORE or
#                                 RVB_KEYSTORE_P12.
#   PATCHER_BUNDLE_ED_PER_BUNDLE  true (morphe): -e/-d ride each --patches arg;
#                                 false (revanced/generic): one trailing group
#   PATCHER_EXP_VERSION_UNSUPPORTED  true => version=exp blocked
#   PATCHER_MOUNT_ARG     "--mount" for module builds, else ""
#   PATCHER_HASH_DEDUP_ELIGIBLE  true => an unchanged rebuild of this tool's
#                                 output is expected to hash equal, so the
#                                 duplicate-build check may suppress publishing.
#                                 revanced/morphe only, mirroring the watcher's
#                                 patch-hash rule: for the other tools cross-run
#                                 hash stability is unmeasured, and a wobbling
#                                 hash would make the check dead code for them.

resolve_patcher() {
	local src="${1,,}"
	local kind flow bundle_re list_arg list_x list_b lv_sub lp_sub has_list any_ver needs_bks signing per_bundle_ed exp_unsup mount keystore_fmt dedup

	case "$src" in
		*"npatch"*|*"lspatch"*)
			kind=xposed; flow=xposed-module; bundle_re="\\.apk$"
			list_arg=""; list_x=""; list_b=""; lv_sub=""; lp_sub=""
			# Only NPatch needs the BouncyCastle provider *in the JVM*: it calls the
			# single-argument KeyStore.getInstance("BKS") and ships its built-in stores
			# as BKS files, and a stock JDK has no BKS type. JingMatrix LSPatch reads
			# its bundled keystore (a JKS file) through KeyStore.getDefaultType(), so
			# it patches fine on a bare Temurin. ReVanced CLI / Morphe also use BKS but
			# bring their own provider, so they are not this step's business.
			# Everything else about the two tools is the same flow - including that
			# both sign the output themselves, so the identity goes to them as -k
			# arguments, in the store format each one can read.
			has_list=false; any_ver=true; signing=true
			needs_bks=false
			if [[ "$src" == *"npatch"* ]]; then
				needs_bks=true; keystore_fmt=bks
			else
				keystore_fmt=pkcs12
			fi
			per_bundle_ed=false; exp_unsup=false; mount=""; dedup=false ;;
		*instafel*)
			kind=instafel; flow=instafel-workflow; bundle_re="\\.(rvp|mpp|jar)$"
			list_arg=""; list_x=""; list_b=""; lv_sub=""; lp_sub="list"
			has_list=false; any_ver=true; needs_bks=false; signing=false
			keystore_fmt=""
			per_bundle_ed=false; exp_unsup=false; mount=""; dedup=false ;;
		*"morphe-desktop"*)
			kind=morphe; flow=cli-patch; bundle_re="\\.(rvp|mpp|jar)$"
			list_arg="--patches"; list_x="-x"; list_b=""; lv_sub="list-versions"; lp_sub="list-patches"
			has_list=true; any_ver=false; needs_bks=false; signing=true
			# The cli-patch flows get --keystore=$RVB_KEYSTORE, i.e. the BKS store:
			# ReVanced CLI reads it with KeyStore.getInstance("BKS", "BC") and has no
			# format conversion, so it is the consumer that fixes the format here
			# (Morphe would accept a PKCS12 store and convert it itself).
			keystore_fmt=bks
			per_bundle_ed=true; exp_unsup=false; mount="--mount"; dedup=true ;;
		*"revanced-cli"*)
			kind=revanced; flow=cli-patch; bundle_re="\\.(rvp|mpp|jar)$"
			list_arg="-p"; list_x=""; list_b="-b"; lv_sub="list-versions"; lp_sub="list-patches"
			has_list=true; any_ver=false; needs_bks=false; signing=true
			# owner-qualified exactly like the original guards: only the official
			# ReVanced/revanced-cli blocks experimental versions
			per_bundle_ed=false
			exp_unsup=false; [[ "$src" == *"revanced/revanced-cli"* ]] && exp_unsup=true
			keystore_fmt=bks
			mount=""; dedup=true ;;
		*)
			# Unknown cli-source: keep today's default semantics (revanced-style
			# listing with -b, morphe-compatible bundle globs, global ed args,
			# --mount in module builds — matching the old 4-way exclusion check).
			kind=generic; flow=cli-patch; bundle_re="\\.(rvp|mpp|jar)$"
			list_arg="-p"; list_x=""; list_b="-b"; lv_sub="list-versions"; lp_sub="list-patches"
			has_list=true; any_ver=false; needs_bks=false; signing=true
			keystore_fmt=bks
			per_bundle_ed=false; exp_unsup=false; mount="--mount"; dedup=false ;;
	esac

	export PATCHER_KIND="$kind" PATCHER_FLOW="$flow" PATCHER_BUNDLE_RE="$bundle_re"
	export PATCHER_LIST_BUNDLE_ARG="$list_arg" PATCHER_LIST_X="$list_x" PATCHER_LIST_B="$list_b"
	export PATCHER_LIST_VERSIONS_SUB="$lv_sub" PATCHER_LIST_PATCHES_SUB="$lp_sub"
	export PATCHER_HAS_PATCH_LIST="$has_list" PATCHER_ANY_VERSION="$any_ver"
	export PATCHER_NEEDS_BKS="$needs_bks" PATCHER_SIGNING="$signing"
	export PATCHER_KEYSTORE_FORMAT="$keystore_fmt"
	export PATCHER_BUNDLE_ED_PER_BUNDLE="$per_bundle_ed"
	export PATCHER_EXP_VERSION_UNSUPPORTED="$exp_unsup"
	export PATCHER_MOUNT_ARG="$mount"
	export PATCHER_HASH_DEDUP_ELIGIBLE="$dedup"
}

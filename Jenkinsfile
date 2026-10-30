// Jenkinsfile — CI for the NetBSD template.
//
// Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
//
// This file is generic: no organisation names, no host names, no
// credentials by value. Everything a site needs is a parameter or an
// environment variable:
//
//   WTFBSD_VM_PROVIDER      the VM provider (default below); a site with
//                           its own hypervisor sets WTFBSD_VM_PROVIDER_PATH
//                           to a provider script outside this repository
//   BUILD_VM_IMAGE          the disk image the build VM boots
//
// The product.conf of the product is a file parameter of the File
// Parameter plugin, so the plugin has to be installed on the Jenkins
// controller: the plugin stashes the uploaded file under the name of
// the parameter, and the pipeline unstashes it into the workspace. The
// parameter is not declared in the parameters block below: the legacy
// file(...) parameter of the core uploads nothing, it points at a file
// on the agent.
//
// The build runs in a throwaway build VM by default: a NetBSD build takes
// hours and a lot of disk. With BUILD_ON_AGENT the build runs on the agent
// itself, which is only sensible for a fast machine that already holds an
// unmodified NetBSD source tree.
//
// Every VM of a build carries the name of the job and the number of the
// build, so that two builds of the same job never share a name. The names
// are written to a list before the VM is created, and the post block
// destroys every VM in the list, even when the build failed in between.

pipeline {
	agent { label "${params.AGENT_LABEL}" }

	parameters {
		string(
			name: 'AGENT_LABEL',
			defaultValue: 'bsd',
			description: 'Label of the Jenkins agent that runs the pipeline (the default is a placeholder: the real label is the one of the site)')
		choice(
			name: 'PROFILE',
			choices: ['desktop', 'appliance', 'both'],
			description: 'appliance = headless, serial console + sshd; desktop = X11 Xfce + LightDM; both = one image of each')
		booleanParam(
			name: 'BUILD_ON_AGENT',
			defaultValue: false,
			description: 'Build on the agent instead of in a build VM')
		// PRODUCT_CONF is the uploaded product configuration: a
		// stashedFile parameter of the File Parameter plugin. The
		// plugin stashes the upload under the parameter name and sets
		// PRODUCT_CONF_FILENAME to the name it was uploaded with; the
		// pipeline unstashes it and copies it to product.conf.
		stashedFile(
			name: 'PRODUCT_CONF',
			description: 'The product configuration (product.conf) written by wtfbsd/agents scripts/apply-answers.sh')
		string(
			name: 'VM_PROVIDER',
			defaultValue: 'bhyve',
			description: 'VM provider used for the build VM and the boot test')
		string(
			name: 'BUILD_VM_NAME',
			defaultValue: 'wtfbsd-build',
			description: 'Name of the build VM, without the name of the job and the number of the build')
		string(
			name: 'BUILD_VM_IMAGE',
			defaultValue: '',
			description: 'Disk image the build VM boots; required when BUILD_ON_AGENT is false')
		string(
			name: 'BUILD_VM_WORKDIR',
			defaultValue: 'wtfbsd-netbsd-template',
			description: 'Directory of this repository inside the build VM')
	}

	environment {
		WTFBSD_VM_PROVIDER = "${params.VM_PROVIDER}"
		// the list of the VMs of this build; the post block destroys
		// every name in it
		VM_LIST = "${WORKSPACE}/.wtfbsd-vm-list"
	}

	stages {
		stage('Validate params') {
			steps {
				script {
					// The File Parameter plugin stashes the uploaded
					// file under the name of the parameter: unstash()
					// writes it into the workspace under that name, and
					// the build always reads the copy named product.conf.
					// The copy is a literal command: the path of the
					// stashed file never reaches the shell.
					// unverified: confirm PRODUCT_CONF_FILENAME with one
					// real upload run. The name has to be a plain file
					// name, so that it can never name a path.
					def uploadedName = env.PRODUCT_CONF_FILENAME ?: ''
					if (!uploadedName) {
						error('no product configuration was uploaded: build with the PRODUCT_CONF file parameter')
					}
					unstash 'PRODUCT_CONF'
					sh 'cp PRODUCT_CONF product.conf'
					// The path of the file the build reads is published
					// under a name of its own: PRODUCT_CONF is the name
					// of the parameter, and Jenkins exports it as an
					// environment variable of the build, which a script
					// may not be allowed to assign to.
					env.CONF_PATH = 'product.conf'
					if (!(uploadedName ==~ /[A-Za-z0-9][A-Za-z0-9._-]*/)) {
						error("the uploaded product configuration has an unexpected name: '${uploadedName}'")
					}
					// the name of the build VM carries the job and the
					// build, and it only holds the characters of a
					// name
					env.BUILD_VM = "${params.BUILD_VM_NAME}-${env.JOB_BASE_NAME}-${env.BUILD_NUMBER}".replaceAll(/[^A-Za-z0-9_.-]/, '')
					// the list of the VMs of this build starts empty
					sh ': > "$VM_LIST"'
					// the build VM is in the list as well: the post
					// block destroys it even when the build stage
					// dies. Every line of the list holds the name of the
					// VM and the slot of its devices, so that the post
					// block destroys it with the same devices.
					sh "printf '%s %s\\n' '${env.BUILD_VM}' 0 >> '${env.VM_LIST}'"
				}
				sh '''
					set -eu
					# the free-text parameters end up in a remote command:
					# they may only hold the characters of a path
					check_param() { # check_param <name> <value>
						case $2 in
						'')
							echo "$1 must not be empty" >&2
							return 1
							;;
						*[!A-Za-z0-9._/-]*)
							echo "$1 must match ^[A-Za-z0-9._/-]+$" >&2
							return 1
							;;
						esac
						return 0
					}
					case "$PROFILE" in
					desktop | appliance | both) ;;
					*) echo "PROFILE must be desktop, appliance or both" >&2; exit 1 ;;
					esac
					[ -n "$AGENT_LABEL" ] || { echo "AGENT_LABEL must not be empty" >&2; exit 1; }
					check_param PROFILE "$PROFILE" || exit 1
					check_param CONF_PATH "$CONF_PATH" || exit 1
					check_param BUILD_VM_WORKDIR "$BUILD_VM_WORKDIR" || exit 1
					[ -f "$CONF_PATH" ] || { echo "no product.conf at $CONF_PATH" >&2; exit 1; }
					[ "$BUILD_ON_AGENT" = true ] || [ -n "$BUILD_VM_IMAGE" ] || {
						echo "BUILD_VM_IMAGE must be set when BUILD_ON_AGENT is false" >&2; exit 1; }
					slug=$(sed -n 's/^DISTRO_SLUG=//p' "$CONF_PATH" | head -1 | tr -cd 'A-Za-z0-9_-')
					arch=$(sed -n 's/^DISTRO_ARCH=//p' "$CONF_PATH" | head -1 | tr -cd 'A-Za-z0-9_')
					[ -n "$slug" ] || { echo "no DISTRO_SLUG in $CONF_PATH" >&2; exit 1; }
					[ -n "$arch" ] || arch=amd64
					printf '%s\n' "$slug" > .distro_slug
					printf '%s\n' "$arch" > .distro_arch
					# the dry run validates the product configuration and
					# prints the whole plan without touching anything
					sh build.sh -c "$CONF_PATH" -n
				'''
			}
		}

		stage('Build') {
			steps {
				script {
					if (params.BUILD_ON_AGENT) {
						sh 'sh build.sh -c "$CONF_PATH" -p "$PROFILE"'
					} else {
						sh '''
							set -eu
							# the slot of the build VM: the boot-test
							# VMs of the same job get another one, so
							# that the two never share a device
							WTFBSD_VM_SLOT=0 sh ci/vm.sh create "$BUILD_VM" "$BUILD_VM_IMAGE"
						'''
						sh '''
							set -eu
							addr=""
							i=0
							while [ "$i" -lt 60 ]; do
								if addr=$(sh ci/vm.sh addr "$BUILD_VM" 2>/dev/null) && [ -n "$addr" ]; then
									break
								fi
								i=$((i + 1))
								sleep 5
							done
							[ -n "$addr" ] || { echo "the build VM never got an address" >&2; exit 1; }
							printf '%s\\n' "$addr" > .build_vm_addr
						'''
						sh '''
							set -eu
							addr=$(cat .build_vm_addr)
							known="$PWD/.known_hosts"
							# the guest must accept the CI key; the site
							# provisions that in its own VM image
							tar -c --exclude=.git . | ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$known" "$addr" "mkdir -p '$BUILD_VM_WORKDIR' && tar -x -C '$BUILD_VM_WORKDIR'"
							# the product configuration is copied to the
							# place the build reads it from, so that it
							# is the same file in the VM and on the agent
							scp -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$known" "$CONF_PATH" "$addr:$BUILD_VM_WORKDIR/product.conf"
							ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$known" "$addr" "cd '$BUILD_VM_WORKDIR' && sh build.sh -c product.conf -p '$PROFILE'"
							scp -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$known" -r "$addr:$BUILD_VM_WORKDIR/out" .
						'''
						// the build VM is not needed any more: it is
						// destroyed here, so that the boot-test VMs
						// never share its devices with it
						sh '''
							set -eu
							sh ci/vm.sh destroy "$BUILD_VM" || true
						'''
					}
				}
			}
		}

		stage('Boot test') {
			steps {
				script {
					def slug = sh(script: 'cat .distro_slug', returnStdout: true).trim()
					def arch = sh(script: 'cat .distro_arch', returnStdout: true).trim()
					def profiles = params.PROFILE == 'both' ? ['appliance', 'desktop'] : [params.PROFILE]
					profiles.each { p ->
						def vmName = "boot-${p}-${env.JOB_BASE_NAME}-${env.BUILD_NUMBER}".replaceAll(/[^A-Za-z0-9_.-]/, '')
						// the name is written to the list before the VM is
						// created, so that the post block destroys it even
						// when the boot test dies
						sh "printf '%s %s\\n' '${vmName}' 1 >> '${env.VM_LIST}'"
						// the slot of the boot-test VM: another one
						// than the build VM of the same job
						sh "WTFBSD_VM_SLOT=1 sh tests/boot-test.sh out/${p}/${slug}-${p}-${arch}.img ${p} '${vmName}'"
					}
				}
			}
		}

		stage('Archive') {
			steps {
				archiveArtifacts(
					artifacts: 'out/**/*.img,out/SHA256',
					allowEmptyArchive: false)
			}
		}
	}

	post {
		always {
			// never leak a VM: every VM the build created is destroyed
			// again, whether the build succeeded or not
			sh '''
				set -eu
				list="${VM_LIST:-}"
				if [ -n "$list" ] && [ -f "$list" ]; then
					while IFS= read -r line; do
						[ -n "$line" ] || continue
						name=${line%% *}
						slot=${line#* }
						if [ "$slot" = "$line" ]; then
							slot=0
						fi
						case $slot in
						'' | *[!0-9]*) slot=0 ;;
						esac
						# the VM is destroyed with the slot of its
						# devices, so that the provider removes the tap
						# of that unit
						WTFBSD_VM_SLOT="$slot" sh ci/vm.sh destroy "$name" || true
					done < "$list"
				fi
			'''
		}
	}
}

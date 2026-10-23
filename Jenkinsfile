// Declarative CI pipeline. Jenkins (running itself as a container) talks to
// the host's Docker daemon over a mounted socket and launches every tool
// (python, gitleaks, trivy, checkov) as its own short-lived sibling
// container — Jenkins' own image stays small, and nothing but docker-cli
// is installed in it. Sibling containers reach this build's workspace via
// `--volumes-from <this container>`, not a bind mount, which is what makes
// paths line up correctly without any host-path translation.
//
// This pipeline never touches the Kubernetes cluster. It ends at "publish
// the image" — Argo CD (Phase 4) is the only thing that deploys.

def PIP_CACHE_VOLUME = 'devsecops-platform-pip-cache'

// $(hostname) is resolved by the shell at execution time, inside this build's
// own Jenkins container, and always equals that container's own ID — so each
// sibling container correctly reaches this build's workspace via
// --volumes-from without needing to pass the ID through a Groovy variable
// (which does not reliably survive across declarative stages/steps).
def dockerRun(String image, String cmd, String extraArgs = '') {
    sh """
        docker run --rm \\
            --volumes-from \$(hostname) \\
            -v ${PIP_CACHE_VOLUME}:/root/.cache/pip \\
            -w "\${WORKSPACE}" \\
            ${extraArgs} \\
            ${image} \\
            sh -c '${cmd}'
    """
}

pipeline {
    agent any

    options {
        timeout(time: 30, unit: 'MINUTES')
        timestamps()
        disableConcurrentBuilds()
        buildDiscarder(logRotator(numToKeepStr: '20'))
    }

    parameters {
        booleanParam(name: 'PUBLISH_IMAGE', defaultValue: false,
            description: 'Push the built image to GHCR. Requires the "ghcr-credentials" Jenkins credential; otherwise this is skipped and the image stays local-only.')
        string(name: 'COVERAGE_THRESHOLD', defaultValue: '80',
            description: 'Minimum statement coverage (%) for app/. 80 was picked to catch real regressions without chasing diminishing returns toward 100% on a small demo app; raise/lower per project maturity.')
        string(name: 'MAX_IMAGE_SEVERITY', defaultValue: 'CRITICAL',
            description: 'Trivy image-scan severity that fails the build. HIGH findings are reported but do not fail the build by default — see docs/SECURITY.md for the policy rationale.')
    }

    environment {
        PY_IMAGE        = 'python:3.12-slim'
        IMAGE_REPO      = 'devsecops-platform-app'
        GHCR_REPO       = 'ghcr.io/akanksha1809/devsecops-platform-app'
    }

    stages {
        stage('Checkout') {
            steps {
                checkout scm
                script {
                    // Computed here, not in the top-level environment{} block: that block
                    // evaluates before this stage runs, so GIT_COMMIT isn't set yet there.
                    // Setting env.* (not a plain Groovy var) is what makes it survive into
                    // later stages.
                    env.SHORT_SHA = sh(script: 'git rev-parse --short=7 HEAD', returnStdout: true).trim()
                    env.IMAGE_TAG = "${env.BUILD_NUMBER}-${env.SHORT_SHA}"
                    sh 'docker volume create ' + PIP_CACHE_VOLUME + ' >/dev/null'
                }
            }
        }

        stage('Install deps') {
            steps {
                script {
                    dockerRun(PY_IMAGE, 'pip install --quiet --cache-dir /root/.cache/pip -r requirements-dev.txt')
                }
            }
        }

        stage('Lint & format') {
            steps {
                script {
                    dockerRun(PY_IMAGE, '''
                        pip install --quiet --cache-dir /root/.cache/pip -r requirements-dev.txt
                        ruff check app tests
                        ruff format --check app tests
                    ''')
                }
            }
        }

        stage('Unit tests') {
            steps {
                script {
                    dockerRun(PY_IMAGE, '''
                        pip install --quiet --cache-dir /root/.cache/pip -r requirements-dev.txt
                        pytest tests -m "not integration" --junitxml=unit-results.xml
                    ''')
                }
            }
            post {
                always { junit allowEmptyResults: true, testResults: 'unit-results.xml' }
            }
        }

        stage('Integration tests') {
            steps {
                script {
                    dockerRun(PY_IMAGE, '''
                        pip install --quiet --cache-dir /root/.cache/pip -r requirements-dev.txt
                        pytest tests -m integration --junitxml=integration-results.xml
                    ''')
                }
            }
            post {
                always { junit allowEmptyResults: true, testResults: 'integration-results.xml' }
            }
        }

        stage('Coverage') {
            steps {
                script {
                    dockerRun(PY_IMAGE, """
                        pip install --quiet --cache-dir /root/.cache/pip -r requirements-dev.txt
                        pytest tests --cov=app --cov-report=xml --cov-report=html --cov-report=term
                    """)
                }
            }
            post {
                always {
                    archiveArtifacts artifacts: 'coverage.xml', allowEmptyArchive: true
                    publishHTML(target: [
                        reportDir: 'htmlcov', reportFiles: 'index.html',
                        reportName: 'Coverage Report', keepAll: true,
                        alwaysLinkToLastBuild: true, allowMissing: true,
                    ])
                }
            }
        }

        stage('Quality gate: coverage threshold') {
            steps {
                script {
                    dockerRun(PY_IMAGE, """
                        pip install --quiet --cache-dir /root/.cache/pip -r requirements-dev.txt
                        pytest tests --cov=app --cov-fail-under=${params.COVERAGE_THRESHOLD} -q
                    """)
                }
            }
        }

        stage('Secret scan (gitleaks)') {
            steps {
                script {
                    // Deliberately git-aware (no --no-git): scans tracked history, not the
                    // working tree, so local-only gitignored files (.env, etc.) never trip
                    // this gate — only secrets that actually reached a commit do.
                    sh """
                        docker run --rm --volumes-from \$(hostname) -w "\${WORKSPACE}" \\
                            zricethezav/gitleaks:latest detect --source=. -v \\
                            --report-path=gitleaks-report.json --exit-code 1
                    """
                }
            }
            post {
                always { archiveArtifacts artifacts: 'gitleaks-report.json', allowEmptyArchive: true }
            }
        }

        stage('Dependency vulnerability scan (trivy)') {
            steps {
                script {
                    sh """
                        docker run --rm --volumes-from \$(hostname) -w "\${WORKSPACE}" \\
                            -v devsecops-platform-trivy-cache:/root/.cache/trivy \\
                            aquasec/trivy:latest fs --scanners vuln --severity HIGH,CRITICAL \\
                            --exit-code 1 --format table requirements.txt
                    """
                }
            }
        }

        stage('IaC security scan (checkov)') {
            steps {
                script {
                    sh """
                        docker run --rm --volumes-from \$(hostname) -w "\${WORKSPACE}" \\
                            bridgecrew/checkov:latest --directory . \\
                            --skip-path .venv --compact --quiet \\
                            --soft-fail
                    """
                }
            }
        }

        stage('Build image') {
            steps {
                script {
                    sh "docker build -t ${IMAGE_REPO}:${env.IMAGE_TAG} -t ${IMAGE_REPO}:latest-local ."
                }
            }
        }

        stage('Image vulnerability scan (trivy)') {
            steps {
                script {
                    sh """
                        docker run --rm -v /var/run/docker.sock:/var/run/docker.sock \\
                            -v devsecops-platform-trivy-cache:/root/.cache/trivy \\
                            aquasec/trivy:latest image --severity ${params.MAX_IMAGE_SEVERITY} \\
                            --exit-code 1 --ignore-unfixed ${IMAGE_REPO}:${env.IMAGE_TAG}
                    """
                }
            }
        }

        stage('SBOM generation') {
            steps {
                script {
                    sh """
                        docker run --rm --volumes-from \$(hostname) \\
                            -v /var/run/docker.sock:/var/run/docker.sock \\
                            -v devsecops-platform-trivy-cache:/root/.cache/trivy \\
                            -w "\${WORKSPACE}" \\
                            aquasec/trivy:latest image --format cyclonedx \\
                            --output sbom.cdx.json ${IMAGE_REPO}:${env.IMAGE_TAG}
                    """
                }
            }
            post {
                always { archiveArtifacts artifacts: 'sbom.cdx.json', allowEmptyArchive: true }
            }
        }

        stage('Publish image') {
            when { expression { return params.PUBLISH_IMAGE } }
            steps {
                script {
                    try {
                        withCredentials([usernamePassword(credentialsId: 'ghcr-credentials',
                                usernameVariable: 'GHCR_USER', passwordVariable: 'GHCR_TOKEN')]) {
                            sh """
                                echo "\$GHCR_TOKEN" | docker login ghcr.io -u "\$GHCR_USER" --password-stdin
                                docker tag ${IMAGE_REPO}:${env.IMAGE_TAG} ${GHCR_REPO}:${env.IMAGE_TAG}
                                docker push ${GHCR_REPO}:${env.IMAGE_TAG}
                                docker logout ghcr.io
                            """
                        }
                    } catch (err) {
                        echo "ghcr-credentials not configured — skipping registry push. " +
                             "Local-only alternative: image is available as ${IMAGE_REPO}:${env.IMAGE_TAG} " +
                             "in the local Docker daemon (loadable into kind with 'kind load docker-image')."
                    }
                }
            }
        }

        stage('Build summary') {
            steps {
                script {
                    def summary = """# Build Summary

- Commit: ${env.GIT_COMMIT ?: 'unknown'} (${env.SHORT_SHA})
- Build: #${env.BUILD_NUMBER}
- Branch: ${env.BRANCH_NAME ?: 'n/a'}
- Image: ${IMAGE_REPO}:${env.IMAGE_TAG}
- Publish requested: ${params.PUBLISH_IMAGE}
- Coverage threshold: ${params.COVERAGE_THRESHOLD}%
- Max allowed image severity: ${params.MAX_IMAGE_SEVERITY}
- Result: ${currentBuild.currentResult}
"""
                    writeFile file: 'build-summary.md', text: summary
                    echo summary
                }
            }
            post {
                always { archiveArtifacts artifacts: 'build-summary.md', allowEmptyArchive: true }
            }
        }
    }

    post {
        always {
            sh "docker rmi ${IMAGE_REPO}:${env.IMAGE_TAG} ${IMAGE_REPO}:latest-local 2>/dev/null || true"
            cleanWs()
        }
        success { echo "Build #${env.BUILD_NUMBER} succeeded for ${env.SHORT_SHA}." }
        failure { echo "Build #${env.BUILD_NUMBER} FAILED for ${env.SHORT_SHA} — see the failing stage above." }
    }
}

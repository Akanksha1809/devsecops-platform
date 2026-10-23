import jenkins.model.*
import hudson.security.*

def env = System.getenv()
def adminUser = env.get("JENKINS_ADMIN_ID")
def adminPass = env.get("JENKINS_ADMIN_PASSWORD")

if (!adminUser || !adminPass) {
    throw new IllegalStateException(
        "JENKINS_ADMIN_ID / JENKINS_ADMIN_PASSWORD must be set — see docker/jenkins/.env.example")
}

def instance = Jenkins.get()

def realm = new HudsonPrivateSecurityRealm(false)
realm.createAccount(adminUser, adminPass)
instance.setSecurityRealm(realm)

def strategy = new FullControlOnceLoggedInAuthorizationStrategy()
strategy.setAllowAnonymousRead(false)
instance.setAuthorizationStrategy(strategy)

instance.save()

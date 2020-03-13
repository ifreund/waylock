use pam::Authenticator;
use users::get_current_username;

pub struct LockAuth {
    login: String,
}

impl LockAuth {
    pub fn new() -> Self {
        let login = get_current_username()
            .unwrap_or_else(|| {
                log::error!("Failed to get current username.");
                panic!();
            })
            .into_string()
            .unwrap_or_else(|_| {
                log::error!("Failed to parse the current username.");
                panic!();
            });
        Self { login }
    }

    /// Attempt to authenticate with PAM. Returns true on success, otherwise false.
    pub fn check_password(&self, password: &str) -> bool {
        let mut authenticator = match Authenticator::with_password("system-auth") {
            Ok(authenticator) => authenticator,
            Err(err) => {
                log::error!("Failed to initialize PAM client: {}", err);
                panic!();
            }
        };
        authenticator.get_handler().set_credentials(&self.login, password);
        match authenticator.authenticate() {
            Ok(()) => true,
            Err(err) => {
                log::warn!("Authentication failure {}", err);
                false
            }
        }
    }
}

from django.utils.translation import gettext_lazy as _

WEBSSO_ENABLED = True
WEBSSO_CHOICES = (
    ("credentials", _("Keystone Credentials")),
    ("zitadel_openid", "Zitadel - SSO"),
)
# Identity provider "keycloak" and Federation protocol "openid"
WEBSSO_IDP_MAPPING = {
    "zitadel_openid": ("zitadel", "openid"),
}
WEBSSO_KEYSTONE_URL = "https://keystone.rpcu.vpn/v3"
WEBSSO_INITIAL_CHOICE = "zitadel_openid"
SECURE_PROXY_SSL_HEADER = ("HTTP_X_FORWARDED_PROTO", "https")
USE_X_FORWARDED_HOST = True
SECURE_SSL_REDIRECT = True

# Use internal endpoint for the Horizon --> Keystone login
WEBSSO_USE_HTTP_REFERER = False

from django.apps import AppConfig


class PluginApp(AppConfig):
    name = "cndfr_speaker_gate"
    verbose_name = "CND France – profil intervenant obligatoire"

    class PretalxPluginMeta:
        name = "CND France – profil intervenant obligatoire"
        author = "Cloud Native Days France"
        description = (
            "Refuse la confirmation d'une proposition tant qu'un de ses intervenants "
            "n'a pas rempli les champs obligatoires de son profil, et le lui signale."
        )
        version = "1.0.0"
        category = "FEATURE"

    def ready(self):
        from . import signals  # noqa: F401 -- registers the receivers

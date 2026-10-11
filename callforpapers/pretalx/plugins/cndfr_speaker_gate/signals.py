"""Make required profile fields binding for every speaker, co-speakers included.

pretalx only checks required speaker fields when someone saves the form that
holds them. A co-speaker who accepts an invitation never goes through the CfP
wizard, so nothing forces them to fill those fields in. This plugin:

- refuses to confirm a proposal while one of its speakers has gaps, naming them;
- shows each speaker what is missing on the pages they land on.
"""

from django.dispatch import receiver
from django.utils.html import format_html
from pretalx.cfp.signals import html_above_profile_page, html_above_submission_list
from pretalx.common.exceptions import SubmissionError
from pretalx.person.models import SpeakerProfile
from pretalx.submission.models import (
    Answer,
    QuestionTarget,
    QuestionVariant,
    SubmissionStates,
)
from pretalx.submission.signals import before_submission_state_change


def _is_filled(answer):
    # A required checkbox (e.g. a consent) only counts once it is ticked,
    # mirroring the CfP form, where a required BooleanField must be True.
    if answer.question.variant == QuestionVariant.BOOLEAN:
        return answer.boolean_answer is True
    return bool((answer.answer_string or "").strip())


def missing_fields(speaker):
    """Labels of the required profile fields ``speaker`` has not filled in."""
    event = speaker.event
    missing = []
    if event.cfp.require_biography and not (speaker.biography or "").strip():
        missing.append("Biographie")
    if event.cfp.require_avatar and not (
        speaker.profile_picture_id and speaker.profile_picture.avatar
    ):
        missing.append("Photo")

    questions = [
        question
        for question in event.questions.filter(target=QuestionTarget.SPEAKER, active=True).order_by(
            "position"
        )
        if question.required
    ]
    filled = {
        answer.question_id
        for answer in Answer.objects.filter(question__in=questions, speaker=speaker)
        .select_related("question")
        .prefetch_related("options")
        if _is_filled(answer)
    }
    missing += [str(q.question) for q in questions if q.pk not in filled]
    return missing


@receiver(before_submission_state_change, dispatch_uid="cndfr_speaker_gate_confirm")
def refuse_incomplete_confirmation(sender, submission, new_state, **kwargs):
    # pk is None while a proposal is being created: it has no speakers yet.
    if new_state != SubmissionStates.CONFIRMED or submission.pk is None:
        return
    incomplete = [
        f"{speaker.name} ({', '.join(missing)})"
        for speaker in submission.speakers.all()
        if (missing := missing_fields(speaker))
    ]
    if incomplete:
        raise SubmissionError(
            "Impossible de confirmer cette proposition : chaque intervenant doit "
            "d'abord compléter son profil. Manquant : " + " ; ".join(incomplete) + "."
        )


@receiver(
    [html_above_submission_list, html_above_profile_page],
    dispatch_uid="cndfr_speaker_gate_banner",
)
def missing_fields_banner(sender, request, **kwargs):
    if not request.user.is_authenticated:
        return ""
    # A plain lookup: User.get_speaker() would create a profile for a stranger.
    speaker = SpeakerProfile.objects.filter(user=request.user, event=sender).first()
    if not speaker or not speaker.submissions.exists():
        return ""
    missing = missing_fields(speaker)
    if not missing:
        return ""
    return format_html(
        '<div class="alert alert-warning">'
        "Il manque des informations obligatoires à votre profil : {}. "
        "Sans elles, votre proposition ne pourra pas être confirmée. "
        '<a href="{}">Compléter mon profil</a>'
        "</div>",
        ", ".join(missing),
        sender.urls.user,
    )

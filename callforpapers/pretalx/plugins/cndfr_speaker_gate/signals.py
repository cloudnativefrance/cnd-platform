"""Make required profile fields binding for co-speakers too (see ../README.md)."""

from django.dispatch import receiver
from django.utils.html import format_html
from pretalx.cfp.signals import html_above_profile_page, html_above_submission_list
from pretalx.common.exceptions import SubmissionError
from pretalx.submission.domain.queries.question import active_questions
from pretalx.submission.models import (
    Answer,
    QuestionTarget,
    QuestionVariant,
    SubmissionStates,
)
from pretalx.submission.signals import before_submission_state_change


def _is_filled(answer):
    # Not Answer.is_answered: it counts whitespace and an unticked checkbox ("No")
    # as answered, while the CfP form requires a required checkbox to be ticked.
    if answer.question.variant == QuestionVariant.BOOLEAN:
        return answer.boolean_answer is True
    return bool((answer.answer_string or "").strip())


def missing_fields(speaker, event):
    """Labels of the required profile fields ``speaker`` has not filled in."""
    missing = []
    if event.cfp.require_biography and not (speaker.biography or "").strip():
        missing.append("Biographie")
    if event.cfp.require_avatar and not speaker.avatar:
        missing.append("Photo")

    questions = [
        question
        for question in active_questions(event, target=QuestionTarget.SPEAKER)
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
        if (missing := missing_fields(speaker, sender))
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
    speaker = request.user.get_speaker(sender, create=False)
    if not speaker or not speaker.submissions.exists():
        return ""
    missing = missing_fields(speaker, sender)
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

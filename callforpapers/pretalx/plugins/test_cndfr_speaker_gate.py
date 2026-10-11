import pytest
from django.conf import settings
from django.contrib.auth.models import AnonymousUser
from django_scopes import scope, scopes_disabled
from pretalx.cfp.signals import html_above_profile_page, html_above_submission_list
from pretalx.common.exceptions import SubmissionError
from pretalx.person.models import SpeakerProfile
from pretalx.submission.models import QuestionTarget, SubmissionStates
from tests.factories import (
    AnswerFactory,
    EventFactory,
    QuestionFactory,
    SpeakerFactory,
    SubmissionFactory,
    UserFactory,
)
from tests.utils import make_request

pytestmark = pytest.mark.django_db

PLUGIN = "cndfr_speaker_gate"
BANNERS = [html_above_submission_list, html_above_profile_page]


def test_plugin_is_discovered_through_its_entry_point():
    assert PLUGIN in settings.PLUGINS


@pytest.fixture
def event():
    # Availabilities would otherwise be required by the confirmation form itself.
    return EventFactory(plugins=PLUGIN, cfp__fields={"availabilities": {"visibility": "optional"}})


@pytest.fixture
def company(event):
    return QuestionFactory(
        event=event,
        target=QuestionTarget.SPEAKER,
        question="Entreprise",
        question_required="required",
    )


def make_speaker(event, **kwargs):
    kwargs.setdefault("biography", "Une biographie.")
    return SpeakerFactory(event=event, **kwargs)


def answer(question, speaker, value="ACME"):
    return AnswerFactory(question=question, speaker=speaker, submission=None, answer=value)


def proposal(event, *speakers, state=SubmissionStates.ACCEPTED):
    talk = SubmissionFactory(event=event, state=state)
    with scopes_disabled():
        talk.speakers.add(*speakers)
    return talk


def confirm(talk, speaker):
    with scope(event=talk.event):
        talk.confirm(person=speaker.user)
        talk.refresh_from_db()
    return talk.state


def banner(signal, event, user):
    request = make_request(event, user)
    with scope(event=event):
        return "".join(str(html) for _, html in signal.send(event, request=request))


def test_confirm_is_refused_while_a_cospeaker_misses_a_required_field(event, company):
    alice = make_speaker(event, name="Alice")
    bob = make_speaker(event, name="Bob")
    answer(company, alice)
    talk = proposal(event, alice, bob)

    with pytest.raises(SubmissionError, match=r"Bob.*Entreprise") as refusal:
        confirm(talk, alice)

    assert "Alice" not in str(refusal.value)
    with scopes_disabled():
        talk.refresh_from_db()
    assert talk.state == SubmissionStates.ACCEPTED


def test_confirm_goes_through_once_every_speaker_answered(event, company):
    alice, bob = make_speaker(event), make_speaker(event)
    answer(company, alice)
    answer(company, bob)
    talk = proposal(event, alice, bob)

    assert confirm(talk, alice) == SubmissionStates.CONFIRMED


def test_blank_answer_counts_as_missing(event, company):
    alice = make_speaker(event, name="Alice")
    answer(company, alice, value="   ")
    talk = proposal(event, alice)

    with pytest.raises(SubmissionError, match="Entreprise"):
        confirm(talk, alice)


def test_unticked_required_consent_counts_as_missing(event):
    consent = QuestionFactory(
        event=event,
        target=QuestionTarget.SPEAKER,
        variant="boolean",
        question="Code de conduite",
        question_required="required",
    )
    alice = make_speaker(event, name="Alice")
    answer(consent, alice, value="False")
    talk = proposal(event, alice)

    with pytest.raises(SubmissionError, match="Code de conduite"):
        confirm(talk, alice)


def test_ticked_required_consent_is_accepted(event):
    consent = QuestionFactory(
        event=event, target=QuestionTarget.SPEAKER, variant="boolean", question_required="required"
    )
    alice = make_speaker(event)
    answer(consent, alice, value="True")
    talk = proposal(event, alice)

    assert confirm(talk, alice) == SubmissionStates.CONFIRMED


def test_optional_speaker_field_does_not_block(event):
    QuestionFactory(event=event, target=QuestionTarget.SPEAKER, question_required="optional")
    alice = make_speaker(event)
    talk = proposal(event, alice)

    assert confirm(talk, alice) == SubmissionStates.CONFIRMED


def test_inactive_speaker_field_does_not_block(event, company):
    company.active = False
    with scopes_disabled():
        company.save()
    alice = make_speaker(event)
    talk = proposal(event, alice)

    assert confirm(talk, alice) == SubmissionStates.CONFIRMED


def test_required_proposal_field_does_not_block(event):
    QuestionFactory(event=event, target=QuestionTarget.SUBMISSION, question_required="required")
    alice = make_speaker(event)
    talk = proposal(event, alice)

    assert confirm(talk, alice) == SubmissionStates.CONFIRMED


def test_missing_required_biography_blocks():
    event = EventFactory(plugins=PLUGIN, cfp__fields={"biography": {"visibility": "required"}})
    alice = make_speaker(event, name="Alice", biography="")
    talk = proposal(event, alice)

    with pytest.raises(SubmissionError, match=r"Alice.*[Bb]iograph"):
        confirm(talk, alice)


def test_missing_optional_biography_does_not_block():
    event = EventFactory(plugins=PLUGIN, cfp__fields={"biography": {"visibility": "optional"}})
    alice = make_speaker(event, biography="")
    talk = proposal(event, alice)

    assert confirm(talk, alice) == SubmissionStates.CONFIRMED


def test_missing_required_avatar_blocks():
    event = EventFactory(plugins=PLUGIN, cfp__fields={"avatar": {"visibility": "required"}})
    alice = make_speaker(event, name="Alice")
    talk = proposal(event, alice)

    with pytest.raises(SubmissionError, match=r"Alice.*[Pp]hoto"):
        confirm(talk, alice)


def test_accepting_a_proposal_is_not_blocked(event, company):
    talk = proposal(event, make_speaker(event), state=SubmissionStates.SUBMITTED)

    with scope(event=event):
        talk.accept()
        talk.refresh_from_db()

    assert talk.state == SubmissionStates.ACCEPTED


def test_event_without_the_plugin_is_not_blocked():
    other = EventFactory()
    QuestionFactory(event=other, target=QuestionTarget.SPEAKER, question_required="required")
    alice = make_speaker(other)
    talk = proposal(other, alice)

    assert confirm(talk, alice) == SubmissionStates.CONFIRMED


@pytest.mark.parametrize("signal", BANNERS)
def test_banner_lists_missing_fields_and_links_to_profile(signal, event, company):
    alice = make_speaker(event)
    proposal(event, alice)

    html = banner(signal, event, alice.user)

    assert "Entreprise" in html
    assert event.urls.user in html


@pytest.mark.parametrize("signal", BANNERS)
def test_banner_is_empty_once_profile_is_complete(signal, event, company):
    alice = make_speaker(event)
    answer(company, alice)
    proposal(event, alice)

    assert banner(signal, event, alice.user) == ""


@pytest.mark.parametrize("signal", BANNERS)
def test_banner_escapes_field_labels(signal, event):
    QuestionFactory(
        event=event,
        target=QuestionTarget.SPEAKER,
        question="<script>x</script>",
        question_required="required",
    )
    alice = make_speaker(event)
    proposal(event, alice)

    html = banner(signal, event, alice.user)

    assert "<script>" not in html
    assert "&lt;script&gt;" in html


@pytest.mark.parametrize("signal", BANNERS)
def test_banner_is_empty_for_users_without_a_proposal(signal, event, company):
    stranger = UserFactory()

    assert banner(signal, event, AnonymousUser()) == ""
    assert banner(signal, event, stranger) == ""
    with scopes_disabled():
        assert not SpeakerProfile.objects.filter(user=stranger).exists()


def test_speaker_is_told_why_confirmation_is_refused(client, event, company):
    alice = make_speaker(event, name="Alice")
    bob = make_speaker(event, name="Bob")
    answer(company, alice)
    talk = proposal(event, alice, bob)
    client.force_login(alice.user)

    response = client.post(talk.urls.confirm, follow=True)

    assert "Bob (Entreprise)" in response.content.decode()
    with scopes_disabled():
        talk.refresh_from_db()
    assert talk.state == SubmissionStates.ACCEPTED


@pytest.mark.parametrize("page", ["user_submissions", "user"])
def test_speaker_pages_show_the_banner(client, event, company, page):
    bob = make_speaker(event)
    proposal(event, bob)
    client.force_login(bob.user)

    html = client.get(getattr(event.urls, page)).content.decode()

    assert "Il manque des informations obligatoires" in html
    assert "Entreprise" in html

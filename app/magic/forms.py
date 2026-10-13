from flask_wtf import FlaskForm
from wtforms import EmailField, StringField, TextAreaField
from wtforms.validators import DataRequired, Email, Length, Optional


class ContactForm(FlaskForm):
    name = StringField("Your name", validators=[DataRequired(), Length(max=100)])
    email = EmailField("Email", validators=[DataRequired(), Email(), Length(max=200)])
    club = StringField("Club (optional)", validators=[Optional(), Length(max=100)])
    message = TextAreaField(
        "Message", validators=[DataRequired(), Length(min=5, max=3000)]
    )
    # Honeypot: hidden from people with CSS, bots tend to fill it in.
    website = StringField("Leave this empty", validators=[Optional()])

import {
  ChangeDetectionStrategy,
  Component,
  effect,
  input,
  output,
  viewChild,
} from '@angular/core';
import { FormControl, FormGroup, ReactiveFormsModule, Validators } from '@angular/forms';

import { CollectionListItem } from '../../../../core/models/collection';
import {
  DEFAULT_QUOTE_BACKGROUND_URL,
  QUOTE_BACKGROUND_OPTIONS,
  QUOTE_LIMITS,
  Quote,
} from '../../../../core/models/quote';
import { Button } from '../../../../shared/components/button/button';
import { Modal } from '../../../../shared/components/modal/modal';
import { SelectField, SelectOption } from '../../../../shared/components/select-field/select-field';
import { TextField } from '../../../../shared/components/text-field/text-field';
import { TextareaField } from '../../../../shared/components/textarea-field/textarea-field';
import { noWhitespace } from '../../../../shared/forms/no-whitespace.validator';

/**
 * What `submitted` emits: the API request fields, plus which collection (if
 * any) the quote should be filed into.
 *
 * `collectionId` rides alongside `CreateQuoteRequest`/`UpdateQuoteRequest`
 * rather than inside them because the API has no such field on either --
 * filing a quote into a collection is a second request
 * (POST /api/collections/{id}/items) the parent makes after the quote itself
 * exists. Callers that don't care about it (the edit flow, where the field is
 * hidden) simply ignore it.
 */
export interface QuoteFormSubmission {
  readonly author: string;
  readonly text: string;
  readonly backgroundImageUrl: string;
  readonly collectionId: number | null;
}

/**
 * The "new quote" dialog: a typed form inside the shared Modal.
 *
 * It reports what the user asked for and nothing more -- `submitted` carries the
 * request, and the parent decides what to do with it. This component never calls
 * the API, which is why it needs no error handling of its own beyond displaying
 * the field errors it is handed.
 */
@Component({
  selector: 'app-quote-form-dialog',
  templateUrl: './quote-form-dialog.html',
  styleUrl: './quote-form-dialog.scss',
  changeDetection: ChangeDetectionStrategy.OnPush,
  imports: [ReactiveFormsModule, Modal, Button, TextField, TextareaField, SelectField],
})
export class QuoteFormDialog {
  /** The signed-in user's collections, to offer as "file into" choices. Empty when the parent has none loaded. */
  readonly collections = input<readonly CollectionListItem[]>([]);
  readonly open = input(false);
  readonly submitting = input(false);
  readonly quote = input<Quote | null>(null);

  /**
   * Field errors from the API's ValidationProblemDetails, keyed as the API keys
   * them ("author", "text"). Passed in rather than fetched, so this component
   * stays ignorant of HTTP.
   */
  readonly fieldErrors = input<Readonly<Record<string, readonly string[]>>>({});

  readonly submitted = output<QuoteFormSubmission>();
  readonly cancelled = output<void>();

  protected readonly limits = QUOTE_LIMITS;
  protected readonly backgroundOptions: readonly SelectOption[] = QUOTE_BACKGROUND_OPTIONS.map(
    (option) => ({
      value: option.url,
      label: option.label,
    }),
  );

  /**
   * `''` (the "None" option) rather than `collections()` being empty is what a
   * value of "no collection chosen" looks like -- SelectOption values are
   * strings because a native `<option>`'s value is, which is also why the id
   * is stringified here and parsed back in `submit()`.
   */
  protected readonly collectionOptions = (): readonly SelectOption[] => [
    { value: '', label: 'None' },
    ...this.collections().map((collection) => ({
      value: collection.id.toString(),
      label: collection.name,
    })),
  ];

  protected readonly form = new FormGroup({
    author: new FormControl('', {
      nonNullable: true,
      validators: [
        Validators.required,
        Validators.maxLength(QUOTE_LIMITS.authorMaxLength),
        noWhitespace(),
      ],
    }),
    text: new FormControl('', {
      nonNullable: true,
      validators: [
        Validators.required,
        Validators.maxLength(QUOTE_LIMITS.textMaxLength),
        noWhitespace(),
      ],
    }),
    backgroundImageUrl: new FormControl(DEFAULT_QUOTE_BACKGROUND_URL, {
      nonNullable: true,
      validators: [Validators.required],
    }),
    // No validators: "None" (`''`) is a legitimate choice, not an incomplete one.
    collectionId: new FormControl('', {
      nonNullable: true,
    }),
  });

  protected readonly modalTitle = () => (this.quote() ? 'Edit quote' : 'New quote');

  // References to the shared field components purely so their native
  // input/textarea/select can be focused programmatically -- the fields
  // themselves still own all aria/validation rendering.
  private readonly authorField = viewChild.required(TextField);
  private readonly textField = viewChild.required(TextareaField);
  private readonly backgroundField = viewChild.required(SelectField);

  constructor() {
    // Opening is what clears the form -- not closing. Clearing on close would
    // wipe what someone typed at the moment a failed submit is telling them to
    // fix it, and this dialog is closed by the parent only after a success.
    effect(() => {
      if (this.open()) {
        const quote = this.quote();

        this.form.reset({
          author: quote?.author ?? '',
          text: quote?.text ?? '',
          backgroundImageUrl: quote?.backgroundImageUrl ?? DEFAULT_QUOTE_BACKGROUND_URL,
          // Quotes don't carry a collection of their own (see QuoteFormSubmission) --
          // there is nothing on `quote` to restore this from, in either mode.
          collectionId: '',
        });
        this.form.markAsUntouched();
      }
    });

    // Server-side validation, moved onto the fields it concerns. A real side
    // effect on non-reactive objects (the controls), driven by a signal input --
    // which is what effect() is for.
    effect(() => {
      const errors = this.fieldErrors();

      const authorRejected = this.applyFieldError(this.form.controls.author, errors['author']?.[0]);
      const textRejected = this.applyFieldError(this.form.controls.text, errors['text']?.[0]);
      const backgroundRejected = this.applyFieldError(
        this.form.controls.backgroundImageUrl,
        errors['backgroundImageUrl']?.[0],
      );

      // A server rejection is exactly as actionable as a client-side one, and
      // deserves the same focus move -- otherwise a keyboard/screen-reader user
      // who submitted a form that looked valid on the client gets no signal that
      // the request failed or which field to fix. Guarded on an actual rejection
      // having just arrived, so this effect's first run (fieldErrors defaults to
      // {}, before the dialog has even opened) does not steal focus.
      if (authorRejected || textRejected || backgroundRejected) {
        this.focusFirstInvalidControl();
      }
    });
  }

  protected submit(): void {
    if (this.form.invalid) {
      this.form.markAllAsTouched();
      this.focusFirstInvalidControl();
      return;
    }

    const { author, text, backgroundImageUrl, collectionId } = this.form.getRawValue();

    // Trimmed here as well as server-side: the API normalises whitespace itself
    // (IQuoteTextNormalizer), so sending " Seneca " would succeed and then come
    // back looking different from what was typed, which reads as the app having
    // changed it.
    this.submitted.emit({
      author: author.trim(),
      text: text.trim(),
      backgroundImageUrl: backgroundImageUrl.trim(),
      // Only meaningful when creating -- the field is hidden in edit mode, so
      // this stays '' (-> null) there regardless of what the control holds.
      collectionId: !this.quote() && collectionId ? Number(collectionId) : null,
    });
  }

  /**
   * Moves focus to the first invalid control's native element, in DOM order
   * (author, then text, then background) -- not whatever order Angular happens
   * to iterate the FormGroup's controls in. Used both for a client-invalid
   * submit and for a server-rejected field arriving via `fieldErrors`.
   */
  private focusFirstInvalidControl(): void {
    if (this.form.controls.author.invalid) {
      this.authorField().focus();
      return;
    }

    if (this.form.controls.text.invalid) {
      this.textField().focus();
      return;
    }

    if (this.form.controls.backgroundImageUrl.invalid) {
      this.backgroundField().focus();
    }
  }

  /** Returns whether this call is what just marked the control invalid. */
  private applyFieldError(control: FormControl<string>, message: string | undefined): boolean {
    if (message) {
      control.setErrors({ apiError: message });
      control.markAsTouched();
      return true;
    }

    // Clearing has to go through re-validation rather than setErrors(null):
    // otherwise dismissing a server error would also drop the client-side rules
    // and let an empty field submit.
    if (control.hasError('apiError')) {
      control.updateValueAndValidity();
    }

    return false;
  }
}

import {
  ChangeDetectionStrategy,
  Component,
  DestroyRef,
  computed,
  effect,
  inject,
  input,
  output,
} from '@angular/core';
import { takeUntilDestroyed } from '@angular/core/rxjs-interop';
import { FormControl } from '@angular/forms';
import { debounceTime, distinctUntilChanged } from 'rxjs';

import { Card } from '../../../../shared/components/card/card';
import { SelectField, SelectOption } from '../../../../shared/components/select-field/select-field';
import { TextField } from '../../../../shared/components/text-field/text-field';

/**
 * Filter and page-size controls for the quotes list.
 *
 * It owns two FormControls and emits their values; it does not own the filter
 * term or the page size, which belong to QuotesStore. That split is why the page
 * can be re-rendered from store state alone -- this component holds nothing that
 * would need restoring.
 *
 * The two subscriptions are the only ones in the application, and they are here
 * because a FormControl's changes arrive as an Observable rather than a signal.
 * takeUntilDestroyed() ties both to this component's lifetime, so neither can
 * outlive it.
 */
@Component({
  selector: 'app-quotes-filter-bar',
  templateUrl: './quotes-filter-bar.html',
  styleUrl: './quotes-filter-bar.scss',
  changeDetection: ChangeDetectionStrategy.OnPush,
  imports: [Card, TextField, SelectField],
})
export class QuotesFilterBar {
  private readonly destroyRef = inject(DestroyRef);

  /** The page size in force, as the store has it. */
  readonly size = input.required<number>();

  /** Sizes to offer. Passed in rather than hardcoded, so the store stays the authority. */
  readonly sizes = input.required<readonly number[]>();

  readonly fetchedCount = input(0);
  readonly matchCount = input(0);
  readonly isFiltering = input(false);
  readonly disabled = input(false);

  readonly searchChange = output<string>();
  readonly sizeChange = output<number>();

  protected readonly searchControl = new FormControl('', { nonNullable: true });
  protected readonly sizeControl = new FormControl('12', { nonNullable: true });

  protected readonly sizeOptions = computed<readonly SelectOption[]>(() =>
    this.sizes().map((size) => ({ value: String(size), label: `${size} per page` })),
  );

  constructor() {
    this.searchControl.valueChanges
      .pipe(debounceTime(250), distinctUntilChanged())
      .pipe(takeUntilDestroyed(this.destroyRef))
      .subscribe((term) => this.searchChange.emit(term));

    this.sizeControl.valueChanges.pipe(takeUntilDestroyed(this.destroyRef)).subscribe((value) => {
      const size = Number(value);

      if (Number.isFinite(size)) {
        this.sizeChange.emit(size);
      }
    });

    // Pushes the authoritative size INTO the control, which is what makes the
    // store the single source of truth: if anything else changes the page size,
    // this select follows. emitEvent: false stops that write from being emitted
    // straight back out as a user change and looping.
    effect(() => {
      const size = String(this.size());

      if (this.sizeControl.value !== size) {
        this.sizeControl.setValue(size, { emitEvent: false });
      }
    });

    // Disabling a FormControl is done through the control, not an attribute --
    // a `[disabled]` attribute on a reactive-forms input is ignored and logs a
    // warning.
    effect(() => {
      const shouldDisable = this.disabled();

      if (shouldDisable && this.sizeControl.enabled) {
        this.sizeControl.disable({ emitEvent: false });
      } else if (!shouldDisable && this.sizeControl.disabled) {
        this.sizeControl.enable({ emitEvent: false });
      }
    });
  }
}

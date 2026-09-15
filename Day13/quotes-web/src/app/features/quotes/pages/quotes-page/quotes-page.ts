import { ChangeDetectionStrategy, Component, OnInit, inject, signal } from '@angular/core';

import { Quote } from '../../../../core/models/quote';
import { Button } from '../../../../shared/components/button/button';
import { ConfirmDialog } from '../../../../shared/components/confirm-dialog/confirm-dialog';
import { EmptyState } from '../../../../shared/components/empty-state/empty-state';
import { ErrorState } from '../../../../shared/components/error-state/error-state';
import { Loader } from '../../../../shared/components/loader/loader';
import { Pagination } from '../../../../shared/components/pagination/pagination';
import {
  QuoteFormDialog,
  QuoteFormSubmission,
} from '../../components/quote-form-dialog/quote-form-dialog';
import { QuotePreviewDialog } from '../../components/quote-preview-dialog/quote-preview-dialog';
import { QuotesFilterBar } from '../../components/quotes-filter-bar/quotes-filter-bar';
import { QuotesGrid } from '../../components/quotes-grid/quotes-grid';
import { CollectionPicker } from '../../services/collection-picker';
import { QUOTE_PAGE_SIZES, QuotesStore } from '../../services/quotes-store';

/**
 * The quotes screen.
 *
 * Everything below is composition and intent -- the page holds no list, no
 * counts and no loading flags. All of that is QuotesStore, provided by THIS
 * COMPONENT below, so it is created when the component is and destroyed with
 * it -- not by the route (see app.routes.ts for why route-level `providers`
 * looks like the same lifecycle and is not, and for the regression this file
 * itself shipped when it briefly disagreed with app.routes.ts's own doc
 * comment about it).
 *
 * The only state that lives here is which dialog is open, because that is not a
 * fact about quotes: it belongs to this screen and nothing else needs it.
 */
@Component({
  selector: 'app-quotes-page',
  templateUrl: './quotes-page.html',
  styleUrl: './quotes-page.scss',
  changeDetection: ChangeDetectionStrategy.OnPush,
  providers: [QuotesStore, CollectionPicker],
  imports: [
    Button,
    Loader,
    EmptyState,
    ErrorState,
    Pagination,
    ConfirmDialog,
    QuotesFilterBar,
    QuotesGrid,
    QuoteFormDialog,
    QuotePreviewDialog,
  ],
})
export class QuotesPage implements OnInit {
  protected readonly store = inject(QuotesStore);

  /**
   * Also the source of the create dialog's "file into a collection" choices --
   * see openCreate(). Sharing this instance rather than fetching separately
   * means opening the create dialog after the per-card menu has already been
   * used (or vice versa) does not ask the API for the same list twice.
   */
  protected readonly picker = inject(CollectionPicker);

  protected readonly pageSizes = QUOTE_PAGE_SIZES;

  protected readonly isCreateOpen = signal(false);
  protected readonly createFieldErrors = signal<Readonly<Record<string, readonly string[]>>>({});
  protected readonly editFieldErrors = signal<Readonly<Record<string, readonly string[]>>>({});
  protected readonly editingQuote = signal<Quote | null>(null);
  protected readonly previewQuote = signal<Quote | null>(null);
  protected readonly previewCanEdit = signal(false);

  /** The quote awaiting delete confirmation. Null means the dialog is closed. */
  protected readonly pendingDelete = signal<Quote | null>(null);

  /**
   * ngOnInit rather than the constructor, and rather than an effect: the first
   * load is a one-off, and there is nothing reactive about it. An effect here
   * would be the mistake this exercise warns about -- it would re-run for reasons
   * unrelated to the user asking for data.
   */
  ngOnInit(): void {
    void this.store.load();
  }

  protected openCreate(): void {
    this.editingQuote.set(null);
    this.createFieldErrors.set({});

    // A failure from the last attempt should not still be on screen while the
    // user makes the next one -- collections-page.ts makes the same call for
    // the same reason.
    this.store.dismissActionError();
    this.isCreateOpen.set(true);

    // Lazy, like the per-card menu's own first open: most visits to this page
    // never open either one, so there is no reason to ask for a list nobody
    // may look at. Guarded on `null` (not loading) so opening the dialog twice
    // in a row does not re-request it.
    if (this.picker.collections() === null) {
      void this.picker.retryLoad();
    }
  }

  protected closeCreate(): void {
    this.isCreateOpen.set(false);
  }

  protected openPreview(quote: Quote): void {
    this.previewQuote.set(quote);
    this.previewCanEdit.set(this.store.isOwnedByCaller(quote));
  }

  protected closePreview(): void {
    this.previewQuote.set(null);
    this.previewCanEdit.set(false);
  }

  protected openEdit(quote: Quote): void {
    if (!this.store.isOwnedByCaller(quote)) {
      return;
    }

    this.isCreateOpen.set(false);
    this.previewQuote.set(null);
    this.previewCanEdit.set(false);
    this.editFieldErrors.set({});
    this.editingQuote.set(quote);
  }

  protected closeEdit(): void {
    this.editingQuote.set(null);
  }

  protected async createQuote(submission: QuoteFormSubmission): Promise<void> {
    const { collectionId, ...request } = submission;
    const fieldErrors = await this.store.create(request, collectionId);

    this.createFieldErrors.set(fieldErrors);

    // The dialog stays open when the API rejected the values, so the messages
    // land next to the fields that caused them.
    if (Object.keys(fieldErrors).length === 0) {
      this.isCreateOpen.set(false);
    }
  }

  protected async updateQuote(submission: QuoteFormSubmission): Promise<void> {
    const quote = this.editingQuote();

    if (!quote) {
      return;
    }

    // collectionId is dropped rather than sent: the edit form hides the field
    // (see QuoteFormDialog), and PUT /api/quotes/{id} has no such field to
    // accept it on.
    const { collectionId: _collectionId, ...request } = submission;
    const fieldErrors = await this.store.update(quote.id, request);
    this.editFieldErrors.set(fieldErrors);

    if (Object.keys(fieldErrors).length === 0) {
      this.editingQuote.set(null);
    }
  }

  protected confirmDelete(quote: Quote): void {
    this.pendingDelete.set(quote);
  }

  protected cancelDelete(): void {
    this.pendingDelete.set(null);
  }

  protected async deleteConfirmed(): Promise<void> {
    const quote = this.pendingDelete();

    if (!quote) {
      return;
    }

    await this.store.remove(quote.id);
    this.pendingDelete.set(null);
  }
}

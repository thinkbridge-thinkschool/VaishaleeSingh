import { Injectable, computed, inject, signal } from '@angular/core';

import { ApiFailure, toApiFailure } from '../../../core/models/api-failure';
import { CreateQuoteRequest, Quote, UpdateQuoteRequest } from '../../../core/models/quote';
import { AuthStore } from '../../../core/services/auth-store';
import { CollectionsApi } from '../../../core/services/collections-api';
import { QuotesApi } from '../../../core/services/quotes-api';
import { QuoteRow } from '../models/quote-row';

/** Page sizes offered in the UI. All within the API's Pagination:MaxPageSize of 100. */
export const QUOTE_PAGE_SIZES = [6, 12, 24, 48] as const;

/**
 * Everything the quotes screen knows, as signals.
 *
 * WHY A STORE AND NOT STATE IN THE PAGE COMPONENT: three components need the
 * same facts -- the grid needs the items, the pagination needs page/size/total,
 * the filter bar needs the query -- and a page component holding all of it would
 * have to pass every piece down and every change back up. Here the page composes
 * the components, and each reads what it needs.
 *
 * WHY IT IS NOT `providedIn: 'root'`: it is provided by the quotes route (see
 * app.routes.ts), so leaving the feature destroys it. A root-provided store would
 * keep the previous user's quotes in memory after sign-out and show them for a
 * frame on the next sign-in.
 *
 * SIGNAL DISCIPLINE, which is the point of the exercise:
 *   - `signal()` for the five facts that are actually pushed in: the fetched
 *     page, the paging parameters, the query, and the in-flight/failed markers.
 *   - `computed()` for everything derivable from them -- the filtered list, the
 *     counts, and each of the four view states. None of these is a signal that
 *     someone has to remember to update.
 *   - `effect()` NOWHERE in this file. Fetching in an effect that reads page and
 *     size looks tidy and is a trap: it re-runs on any read signal changing, so a
 *     size change fires two requests, and there is no way to await it or to
 *     cancel the loser. Loading is triggered explicitly by the four methods at
 *     the bottom, each of which is a thing the user did.
 */
@Injectable()
export class QuotesStore {
  private readonly api = inject(QuotesApi);
  private readonly collectionsApi = inject(CollectionsApi);
  private readonly authStore = inject(AuthStore);

  // --- Raw state -------------------------------------------------------------
  private readonly quotes = signal<readonly Quote[]>([]);
  private readonly totalCount = signal(0);
  private readonly pageNumber = signal(1);
  private readonly pageSize = signal<number>(12);
  private readonly query = signal('');

  private readonly loading = signal(false);
  private readonly failure = signal<ApiFailure | null>(null);
  private readonly creating = signal(false);
  private readonly updating = signal(false);
  private readonly deletingQuoteId = signal<number | null>(null);
  private loadSequence = 0;

  /**
   * A create, update or delete that failed for a reason OTHER than a
   * validation problem -- a 401, a 403, a 500. Kept apart from `failure`
   * (a failed LOAD) for the reason recorded on CollectionsStore's own copy of
   * this signal, which this one is the original of: collapsing the two meant a
   * refused mutation blanked the entire page behind "Could not load quotes",
   * which reads as the whole screen breaking rather than as one action being
   * refused. Verified directly -- forcing a delete to 403 with this signal
   * removed reproduces exactly that: "Could not load quotes / Only the person
   * who created this quote can delete it" replacing a page of otherwise
   * perfectly good quotes.
   */
  private readonly mutationFailure = signal<ApiFailure | null>(null);

  // --- Readonly projections --------------------------------------------------
  readonly page = this.pageNumber.asReadonly();
  readonly size = this.pageSize.asReadonly();
  readonly total = this.totalCount.asReadonly();
  readonly search = this.query.asReadonly();
  readonly isLoading = this.loading.asReadonly();
  readonly error = this.failure.asReadonly();
  readonly isCreating = this.creating.asReadonly();
  readonly isUpdating = this.updating.asReadonly();
  readonly deletingId = this.deletingQuoteId.asReadonly();
  readonly actionError = this.mutationFailure.asReadonly();

  /** The current server-filtered page. The API owns the full-database search. */
  readonly items = computed(() => this.quotes());

  /**
   * The items paired with the two things a card cannot work out for itself.
   *
   * The alternative -- passing the signed-in user id down to every card and
   * repeating `quote.createdByUserId === null || ... === userId` in the template
   * -- would put an authorization rule in a presentation component, in as many
   * copies as there are places that render a quote.
   */
  readonly rows = computed<readonly QuoteRow[]>(() =>
    this.items().map((quote) => ({
      quote,
      owned: this.isOwnedByCaller(quote),
      deletable: this.canDelete(quote),
    })),
  );

  readonly isFiltering = computed(() => this.query().trim().length > 0);
  readonly fetchedCount = computed(() => this.quotes().length);
  readonly matchCount = computed(() => this.totalCount());

  /**
   * The four view states, derived rather than tracked. A separate `isEmpty`
   * signal set by hand in load() is the classic source of a page that shows an
   * empty state and a list at the same time.
   */
  readonly showLoading = computed(() => this.loading() && this.quotes().length === 0);
  readonly showError = computed(() => !this.loading() && this.failure() !== null);
  readonly showEmpty = computed(
    () =>
      !this.loading() &&
      this.failure() === null &&
      this.quotes().length === 0 &&
      !this.isFiltering(),
  );
  readonly showNoMatches = computed(
    () =>
      !this.showLoading() &&
      this.isFiltering() &&
      this.failure() === null &&
      this.matchCount() === 0,
  );

  /**
   * True while a page other than the first render is loading -- used to disable
   * paging controls without replacing the list with a skeleton, so the content
   * does not flash out and back in when moving between pages.
   */
  readonly isRefreshing = computed(() => this.loading() && this.quotes().length > 0);

  /**
   * Whether the signed-in user may delete a given quote.
   *
   * Mirrors the API's strict ownership rule (MustOwnQuoteHandler): only the
   * creator may delete it. Getting this wrong shows a delete button that always
   * 403s -- it cannot grant anything, because the API decides.
   */
  canDelete(quote: Quote): boolean {
    return this.isOwnedByCaller(quote);
  }

  /**
   * Whether this user actually WROTE it -- a narrower question than canDelete,
   * and the one the "yours" badge answers. A quote with no recorded creator is
   * deletable by anyone and authored by nobody in particular, so it gets the
   * control and not the badge.
   */
  isOwnedByCaller(quote: Quote): boolean {
    return quote.createdByUserId !== null && quote.createdByUserId === this.authStore.userId();
  }

  // --- Commands --------------------------------------------------------------

  /** Fetches the current page. Every other method that changes state calls this. */
  async load(): Promise<void> {
    const sequence = ++this.loadSequence;
    this.loading.set(true);
    this.failure.set(null);
    this.mutationFailure.set(null);

    try {
      const author = this.query().trim();
      const result = author
        ? await this.api.getPage(this.pageNumber(), this.pageSize(), author)
        : await this.api.getPage(this.pageNumber(), this.pageSize());

      if (sequence !== this.loadSequence) {
        return;
      }

      this.quotes.set(result.items);
      this.totalCount.set(result.total);
    } catch (error) {
      if (sequence !== this.loadSequence) {
        return;
      }

      this.failure.set(toApiFailure(error));

      // Cleared on failure on purpose: leaving the previous page's rows on
      // screen under an error message claims data that may no longer be true.
      this.quotes.set([]);
      this.totalCount.set(0);
    } finally {
      if (sequence === this.loadSequence) {
        this.loading.set(false);
      }
    }
  }

  async goToPage(page: number): Promise<void> {
    if (page === this.pageNumber() || page < 1) {
      return;
    }

    this.pageNumber.set(page);
    await this.load();
  }

  async setSize(size: number): Promise<void> {
    if (size === this.pageSize()) {
      return;
    }

    this.pageSize.set(size);

    // Back to page 1: page 4 of a 6-per-page list does not exist at 48 per page,
    // and asking for it returns an empty list that looks like a bug.
    this.pageNumber.set(1);
    await this.load();
  }

  setSearch(term: string): void {
    const nextTerm = term.trim();

    if (nextTerm === this.query()) {
      return;
    }

    this.query.set(nextTerm);
    this.pageNumber.set(1);
    void this.load();
  }

  /**
   * Creates a quote and returns the field errors the API reported, so the form
   * can attach them to its controls. An empty object means it worked.
   *
   * Returning errors rather than throwing: a validation failure is an ordinary
   * outcome of a form submission, not an exception, and the caller has to handle
   * it either way.
   *
   * `collectionId`, when given, files the newly created quote into that
   * collection with a second request (there is no single API call for both --
   * see QuoteFormSubmission). A failure of that second call does not fail the
   * create: the quote itself was made successfully, so it is reported through
   * `actionError` rather than as a field error on a form that already worked.
   */
  async create(
    request: CreateQuoteRequest,
    collectionId: number | null = null,
  ): Promise<Readonly<Record<string, readonly string[]>>> {
    this.creating.set(true);

    try {
      const created = await this.api.create(request);

      if (collectionId !== null) {
        try {
          await this.collectionsApi.addItem(collectionId, { quoteId: created.id });
        } catch (error) {
          this.mutationFailure.set(toApiFailure(error));
        }
      }

      // Straight to page 1 and re-fetch, rather than pushing the created quote
      // into the current page's array. The list is server-paged and server
      // ordered, so a locally inserted row would sit in a position the API would
      // not have put it in, and the page's `total` would be stale.
      this.pageNumber.set(1);
      this.query.set('');
      await this.load();

      return {};
    } catch (error) {
      const failure = toApiFailure(error);

      // A validation problem belongs on the form's fields. Anything else (a 401,
      // a 500) is an ACTION failure, not a page failure -- see mutationFailure's
      // own comment for what setting `failure` here used to do.
      if (Object.keys(failure.fieldErrors).length > 0) {
        return failure.fieldErrors;
      }

      this.mutationFailure.set(failure);
      return {};
    } finally {
      this.creating.set(false);
    }
  }

  /** Edits a quote and returns API field errors keyed by field name, if any. */
  async update(
    id: number,
    request: UpdateQuoteRequest,
  ): Promise<Readonly<Record<string, readonly string[]>>> {
    this.updating.set(true);

    try {
      await this.api.update(id, request);
      await this.load();
      return {};
    } catch (error) {
      const failure = toApiFailure(error);

      if (Object.keys(failure.fieldErrors).length > 0) {
        return failure.fieldErrors;
      }

      this.mutationFailure.set(failure);
      return {};
    } finally {
      this.updating.set(false);
    }
  }

  /** Deletes a quote, then re-reads the page it was on. */
  async remove(id: number): Promise<void> {
    this.deletingQuoteId.set(id);

    try {
      await this.api.delete(id);

      // Deleting the only row on the last page would otherwise leave the user
      // looking at an empty page 3 of 2.
      const wasLastOnPage = this.quotes().length === 1 && this.pageNumber() > 1;
      if (wasLastOnPage) {
        this.pageNumber.update((page) => page - 1);
      }

      await this.load();
    } catch (error) {
      // Can legitimately 403 -- MustOwnQuoteHandler refuses a delete on a quote
      // this caller does not own -- and that must not clear the list either.
      this.mutationFailure.set(toApiFailure(error));
    } finally {
      this.deletingQuoteId.set(null);
    }
  }

  /** Clears a create/update/delete failure once it has been seen. */
  dismissActionError(): void {
    this.mutationFailure.set(null);
  }
}

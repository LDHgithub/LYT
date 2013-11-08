# Requires `/common`
# Requires `/support/lyt/utils`
# Requires `/models/service/service`
# Requires `playlist`
# Requires `dtb/nccdocument`

# -------------------

# This class models a book for the purposes of playback.

window.BOOK_ISSUE_CONTENT_ERROR        = {}
window.BOOK_CONTENT_RESOURCES_ERROR    = {}
window.BOOK_NCC_NOT_FOUND_ERROR        = {}
window.BOOK_NCC_NOT_LOADED_ERROR       = {}
window.BOOK_BOOKMARKS_NOT_LOADED_ERROR = {}

class LYT.Book

  # Factory-method
  # Note: Instances are cached in memory
  this.load = do ->
    loaded = {}

    (id) ->
      deferred = jQuery.Deferred()

      loaded[id] or= new LYT.Book id

      # Book is loaded; load its playlist
      loaded[id].done (book) ->
        #book.playlist or= new LYT.Playlist book
        #book.playlist.fail (error) -> deferred.reject error
        #book.playlist.done -> 
        deferred.resolve book

      # Book failed
      loaded[id].fail (error) ->
        loaded[id] = null
        deferred.reject error

      deferred.promise()


  # "Class"/"static" method for retrieving a
  # book's metadata
  # Note: Results are cached in memory
  #
  # DEPRECATED: Use `catalog.getDetails()` instead
  this.getDetails = do ->
    loaded = {}
    (id) ->
      log.warn "Book.getDetails is deprecated. Use catalog.getDetails() instead"
      deferred = jQuery.Deferred()
      if loaded[id]?
        deferred.resolve loaded[id]
        return deferred

      LYT.service.getMetadata(id)
      .done (metadata) ->
        loaded[id] = metadata
        deferred.resolve metadata

      .fail (args...) ->
        deferred.reject args...

      deferred.promise()


  # The constructor takes one argument; the ID of the book.
  # The instantiated object acts as a Deferred object, as the instantiation of a book
  # requires several RPCs and file downloads, all of which are performed asynchronously.
  #
  # Here's an example of how to load a book for playback:
  #
  #     # Instantiate the book
  #     book = new LYT.Book 123
  #
  #     # Set up a callback for when the book's done loading
  #     # The callback receives the book object as its argument
  #     book.done (book) ->
  #       # Do something with the book
  #
  #     # Set up a callback to handle any failure to load the book
  #     book.fail () ->
  #       # Do something about the failure
  #
  constructor: (@id) ->
    # Create a Deferred, and link it to `this`
    deferred = jQuery.Deferred()
    deferred.promise this

    @resources   = {}
    @nccDocument = null

    pending = 2
    resolve = =>
      --pending or deferred.resolve this

    # First step: Request that the book be issued
    issue = =>
      # Perform the RPC
      issued = LYT.service.issue @id

      # When the book has been issued, proceed to download
      # its resources list, ...
      issued.then getResources

      # ... or fail
      issued.fail -> deferred.reject BOOK_ISSUE_CONTENT_ERROR

    # Second step: Get the book's resources list
    getResources = =>
      # Perform the RPC
      got = LYT.service.getResources @id

      # If fail, then fail
      got.fail -> deferred.reject BOOK_CONTENT_RESOURCES_ERROR

      got.then (@resources) =>
        ncc = null

        # Process the resources hash
        for own localUri, uri of @resources
          # Each resource is identified by its relative path,
          # and contains the properties `url` and `document`
          # (the latter initialized to `null`)
          # Urls are rewritten to use the origin server just
          # in case we are behind a proxy.
          origin = document.location.href.match(/(https?:\/\/[^\/]+)/)[1]
          path = uri.match(/https?:\/\/[^\/]+(.+)/)[1]
          @resources[localUri] =
            url:      origin + path
            document: null

          # If the url of the resource is the NCC document,
          # save the resource for later
          if (/^ncc\.x?html?$/i).test localUri then ncc = @resources[localUri]

        # If an NCC reference was found, go to the next step:
        # Getting the NCC document, and the bookmarks in
        # parallel. Otherwise, fail.
        if ncc?
          getNCC ncc
          getBookmarks()
        else
          deferred.reject BOOK_NCC_NOT_FOUND_ERROR


    # Third step: Get the NCC document
    getNCC = (obj) =>
      # Instantiate an NCC document
      ncc = new LYT.NCCDocument obj.url, @resources

      # Propagate a failure
      ncc.fail -> deferred.reject BOOK_NCC_NOT_LOADED_ERROR

      #
      ncc.then (document) =>
        obj.document = @nccDocument = document

        metadata = @nccDocument.getMetadata()

        # Get the author(s)
        creators = metadata.creator or []
        @author = LYT.utils.toSentence (creator.content for creator in creators)

        # Get the title
        @title = metadata.title?.content or ""

        # Get the total time
        @totalTime = metadata.totalTime?.content or ""

        ncc.book = this

        resolve()

    getBookmarks = =>
      @lastmark  = null
      @bookmarks = []

      # Resolve and return early if bookmarks aren't supported
      # unless LYT.service.bookmarksSupported()
      #   resolve()
      #   return

      log.message "Book: Getting bookmarks"
      process = LYT.service.getBookmarks(@id)

      # TODO: perhaps bookmarks should be loaded lazily, when required?
      process.fail -> deferred.reject BOOK_BOOKMARKS_NOT_LOADED_ERROR

      process.done (data) =>
        if data?
          @lastmark = data.lastmark
          @bookmarks = data.bookmarks
          @_normalizeBookmarks()
        resolve()




    # Kick the whole process off
    issue @id

  # ----------

  # Gets the book's metadata (as stated in the NCC document)
  getMetadata: ->
    @nccDocument?.getMetadata() or null

  saveBookmarks: -> LYT.service.setBookmarks this

  _normalizeBookmarks: ->
    # Delete all bookmarks that are very close to each other
    temp = {}
    for bookmark in @bookmarks
      temp[bookmark.URI] or= []
      # Find an index for this bookmark: either at the end of the array
      # or at the location of anohter bookmark very close to this one
      i = 0
      while i < temp[bookmark.URI].length
        saved = temp[bookmark.URI][i]
        if -2 < saved.timeOffset - bookmark.timeOffset < 2
          break
        i++
      temp[bookmark.URI][i] = bookmark

    @bookmarks = []
    @bookmarks = @bookmarks.concat bookmarks for uri, bookmarks of temp

    # Sort them
    # TODO: Sort using chronographical order (implement LYT.Bookmark.compare)
    cmp = (a, b) ->
      return 1 if not b?
      return -1 if not a?
      if a > b
        1
      else if a < b
        -1
      else 0

    @bookmarks = @bookmarks.sort (a, b) ->
      if a.note? and b.note?
        cmp a.note.text, b.note.text
      else if a.title? and b.title?
        cmp a.title.text, b.title.text
      else
        true

  # TODO: Sort bookmarks in reverse chronological order
  # TODO: Add remove bookmark method
  addBookmark: (segment, offset = 0) ->
    @bookmarks or= []
    @bookmarks.push segment.bookmark offset
    @_normalizeBookmarks()
    @saveBookmarks()

  setLastmark: (segment, offset = 0) ->
    @lastmark = segment.bookmark offset
    @saveBookmarks()

  #This part describes the playlist features of the book class
  currentSection: -> @currentSegment?.section

  hasNextSegment: -> @currentSegment?.hasNext() or @hasNextSection()

  hasPreviousSegment: -> @currentSegment?.hasPrevious() or @hasPreviousSection()

  hasNextSection: -> @currentSection()?.next?

  hasPreviousSection: -> @currentSection()?.previous?

  load: (segment) ->
    log.message "Playlist: load: queue segment #{segment.url?() or '(N/A)'}"
    segment.done (segment) =>
      if segment?
        log.message "Playlist: load: set currentSegment to [#{segment.url()}, #{segment.start}, #{segment.end}, #{segment.audio}]"
        @currentSegment = segment
    segment

  rewind: -> @load @nccDocument.firstSegment()

  nextSection: ->
    # FIXME: loading segments is the responsibility of the section each
    # each segment belongs to.
    if @currentSection().next
      @currentSection().next.load()
      @load @currentSection().next.firstSegment()

  previousSection: ->
    # FIXME: loading segments is the responsibility of the section each
    # each segment belongs to.
    @currentSection().previous.load()
    @load @currentSection().previous.firstSegment()

  nextSegment: ->
    if @currentSegment.hasNext()
      # FIXME: loading segments is the responsibility of the section each
      # each segment belongs to.
      @currentSegment.next.load()
      return @load @currentSegment.next
    else
      return @nextSection()

  previousSegment: ->
    if @currentSegment.hasPrevious()
      # FIXME: loading segments is the responsibility of the section each
      # each segment belongs to.
      @currentSegment.previous.load()
      return @load @currentSegment.previous
    else
      if @currentSection().previous
        @currentSection().previous.load()
        @currentSection().previous.pipe (section) =>
          @load section.lastSegment()

  # Will rewind to start if no url is provided
  segmentByURL: (url) ->
    if url?
      if segment = @nccDocument.getSegmentByURL(url)
        return @load segment
    else
      return @rewind()

  # Get the following segment if we are very close to the end of the current
  # segment and the following segment starts within the fudge limit.
  _fudgeFix: (offset, segment, fudge = 0.1) ->
    segment = segment.next if segment.end - offset < fudge and segment.next and offset - segment.next.start < fudge
    return segment

  segmentByAudioOffset: (audio, offset = 0, fudge = 0.1) ->
    if not audio? or audio is ''
      log.error 'Playlist: segmentByAudioOffset: audio not provided'
      return jQuery.Deferred().reject('audio not provided')
    deferred = jQuery.Deferred()
    promise = @searchSections (section) =>
      for segment in section.document.segments
        # Using 0.01s to cover rounding errors (yes, they do occur)
        if segment.audio is audio and segment.start - 0.01 <= offset < segment.end + 0.01
          segment = @_fudgeFix offset, segment
          # FIXME: loading segments is the responsibility of the section each
          # each segment belongs to.
          log.message "Playlist: segmentByAudioOffset: load segment #{segment.url()}"
          segment.load()
          return @load segment
    promise.done (segment) ->
      segment.done -> deferred.resolve segment
    promise.fail -> deferred.reject()
    deferred.promise()

  # Search for sections using a callback handler
  # Returns a jQuery promise.
  # handler: callback that will be called with one section at a time.
  #          If handler returns anything trueish, the search will stop
  #          and the promise will resolve with the returned trueish.
  #          If the handler returns anything falseish, the search will
  #          continue by calling handler once again with a new section.
  #
  #          If the handler exhausts all sections, the promise will reject
  #          with no return value.
  #
  # start:   the section to start searching from (default: current section).
  searchSections: (handler, start = @currentSection()) ->

    # The use of iterators below can easily be adapted to the Strategy
    # design pattern, accommodating other search orders.

    # Generate an iterator with start value start and nextOp to generate
    # the next value.
    # Will stop calling nextOp as soon as nextOp returns null or undefined
    makeIterator = (start, nextOp) ->
      current = start
      return ->
        result = current
        current = nextOp current if current?
        return result

    # This iterator configuration will make the iterator return this:
    # this
    # this.next
    # this.previous
    # this.next.next
    # this.previous.previous
    # ...
    iterators = [
      makeIterator start, (section) -> section.previous
      makeIterator start, (section) -> section.next
    ]

    # This iterator will query the iterators in the iterators array one at a
    # time and remove them from the array if they stop returning anything.
    i = 0
    iterator = ->
      result = null
      while not result? and i < iterators.length
        result = iterators[i].apply()
        iterators.splice(i) if not result?
        i++
        i %= iterators.length
        return result if result

    searchNext = () ->
      if section = iterator()
        section.load()
        return section.pipe (section) ->
          if result = handler section
            return jQuery.Deferred().resolve(result)
          else
            return searchNext()
      else
        return jQuery.Deferred().reject()

    searchNext()

  segmentBySectionOffset: (section, offset = 0) ->
    @load section.pipe (section) -> @_fudgeFix offset, section.getSegmentByOffset offset



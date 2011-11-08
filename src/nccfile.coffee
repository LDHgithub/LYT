# This class models an NCC (Navigation Control Center) file
#
#

do ->
  
  class LYT.NCCDocument
    constructor: (@url) ->
      deferred = jQuery.Deferred()
      deferred.promise this
      
      jQuery.ajax {
        url:      @url
        dataType: "xml"
        async:    true
        cache:    true
        success: (xml, status, xhr) =>
          @xml = jQuery xml
          @structure = parseStructure @xml
          @metadata  = parseMetadata @xml
          deferred.resolve()
        
        error: ->
          deferred.reject(xhr, status, error)
      }
    
    toJSON: ->
      return null unless @structure? and @metadata?
      structure: @structure
      metadata:  @metadata || false
    
    creators: ->
      return ["?"] unless @metadata.creator?
      creators = (creator.content for creator in @metadata.creator)
      if creators.length > 1
        creators.slice(0, -1).join(", ") + " & " + creators.pop()
      else
        creators[0]
    
    getTextById: (id) ->
      id = id.replace /^[^#]*/, ''
      jQuery.trim @xml.find(id).first().text()
    
    # Convert the structure tree to an HTML nested list   
    # FIXME: This shouldn't be here... it should be in gui or something
    toHTMLList: ->
      # Recursively builds nested ordered lists from an array of items
      mapper = (items) ->
        list = jQuery "<ol></ol>"
        for item in items
          element = jQuery "<li></li>"
          element.attr "id", item.id
          element.attr "data-href", item.href
          element.attr "data-class", item.class
          element.text item.text
          element.append mapper(item.children) if item.children?
          list.append element
        list
      
      # Create the wrapper unordered list
      element = jQuery "<ul></ul>"
      element.attr "data-title", @metadata.title.content
      element.attr "data-creator", @creators()
      element.attr "data-totalTime", @metadata.totalTime.content
      element.attr "id", "NCCRootElement"
      element.attr "data-role", "listview"
      element.append mapper(@structure).html()
      element
    
    firstSection: ->
      @structure[0] or null
    
    findSection: (id) ->
      find = (id, sections) ->
        for section in sections
          if section.id is id
            return section
          else if section.children?
            child = find id, section.children
            return child if child?
        
        return null
      
      find @structure
    
    toJSON: ->
      return null unless @structure? and @metadata?
      structure: @structure
      metadata:  @metadata || false
    
  
  # ---------
  
  # ## Parsing functions
  
  # Parses `<meta>` nodes in the head-element
  parseMetadata = (xml) ->
    selectors = 
      # Name attribute values for nodes that appear 0-1 times per file  
      # TODO: Move these to config?
      singular: [
        "dc:coverage"
        "dc:date"
        "dc:description"
        ["dc:format", "ncc:format"]
        ["dc:identifier", "ncc:identifier"]
        "dc:publisher"
        "dc:relation"
        "dc:rights"
        "dc:source"
        "dc:subject"
        "dc:title"
        "dc:type"
        "ncc:charset"
        "ncc:depth"
        "ncc:files"
        "ncc:footnotes"
        "ncc:generator"
        "ncc:kByteSize"
        "ncc:maxPageNormal"
        "ncc:multimediaType"
        "ncc:pageFront", "ncc:page-front"
        "ncc:pageNormal", "ncc:page-normal"
        ["ncc:pageSpecial", "ncc:page-special"]
        "ncc:prodNotes"
        "ncc:producer"
        "ncc:producedDate"
        "ncc:revision"
        "ncc:revisionDate"
        ["ncc:setInfo", "ncc:setinfo"]
        "ncc:sidebars"
        "ncc:sourceDate"
        "ncc:sourceEdition"
        "ncc:sourcePublisher"
        "ncc:sourceRights"
        "ncc:sourceTitle"
        ["ncc:tocItems", "ncc:tocitems"]
        ["ncc:totalTime", "ncc:totaltime"]
      ]
      # Name attribute values for nodes that may appear multiple times per file
      plural: [
        "dc:contributor"
        "dc:creator"
        "dc:language"
        "ncc:narrator"
      ]
    
    # Finds nodes by the given name attribute value(s) _(multiple values given as an array)_
    findNodes = (selectors) ->
      selectors = [selectors] unless selectors instanceof Array
      name = selectors[0].replace /[^:]+:/, ''
      nodes = []
      while selectors.length > 0
        selector = "meta[name='#{selectors.shift()}']"
        xml.find(selector).each ->
          node = jQuery this
          obj = {}
          obj.content = node.attr("content")
          obj.scheme  = node.attr("scheme") if node.attr "scheme"
          nodes.push obj
      
      return null if nodes.length is 0
      { nodes: nodes, name: name }
    
    xml = xml.find("head").first()
    metadata = {}
    for selector in selectors.singular
      found = findNodes selector
      if found?
        metadata[found.name] = found.nodes.shift()
    
    for selector in selectors.plural
      found = findNodes selector
      if found?
        metadata[found.name] = jQuery.makeArray found.nodes
    
    metadata
  
  
  class Section
    constructor: (values) ->
      jQuery.extend this, values
      
    flatten: ->
      flat = [this]
      if @children
        flat = flat.concat child.flatten() for child in @children
      return flat
    
    smilURLs: ->
      section.href for section in @flatten
        
  
  
  # Parses the structure of headings (and heading only) in the NCC file into a nested array (a tree)  
  # **Note:** This function absolutely relies on the NCC file being well-formed
  parseStructure = (xml) ->
    # Collects consecutive heading of the given level, and recursively collects each of their "children", and so on…
    getConsecutive = (headings, level, collector) ->
      for heading, index in headings
        return index if heading.tagName.toLowerCase() isnt "h#{level}"
        heading = jQuery heading
        link = heading.find("a").first()
        node = new Section {
          text:    link.text()
          url:     link.attr "href"
          id:      heading.attr "id"
          class:   heading.attr "class"
        }
        children = []
        index += getConsecutive headings.slice(index+1), level+1, children
        node.children = children if children.length > 0
        collector.push node
      
      headings.length
    
    headings  = jQuery.makeArray xml.find(":header")
    level     = parseInt headings[0].tagName.slice(1), 10
    structure = []
    
    getConsecutive headings, level, structure
    structure
  

### ToDo
##  Manage name conflicts between sheets and ranges and perhaps among ranges 

## Print comments
## cat(grep("##", readLines('xlx.r'), value=T), sep='\n')

## Credit where credit's due:
## Schaun Wheeler xlsxToR, while less feature rich is contains the relevant ideas


read.xlx= function(
    file, sheets=NULL, header.sheets=FALSE, header.ranges=FALSE, ranges=NULL,
    keepblanks=FALSE, allchars=FALSE, general='character', simplify=TRUE, info=FALSE) {

    require(XML)
    require(plyr)
    require(pbapply)
   

    ## Global variables 
    ## ----------------
    
    T=TRUE; F=FALSE
    tdir=NULL         # Temporary dir
    os_origin ="1899-12-30" # Apparently non-MAC only  
    wbsheets=NULL      # Sheets names (preserved after sheet selection)
    wbranges=NULL      # Range names (as opposed to argument ranges) 
    rgsheets=NULL      # Sheets names referenced by ranges
    rgrefs  =NULL      # Named ranges as references  
    actsheets=NULL     # DF with properties of actual sheets to be processed.
                       # Updated on going, based on processing rules  
    usheets=sheets     # User sheets (fast code search), 
    usheets.dirty=NULL # User sheets non-blank    
    uranges=ranges     # User names ranges for fast code search
    is.header.sheets=!is.null(as.list(sys.call())$header.sheets)
    is.header.ranges=!is.null(as.list(sys.call())$header.ranges)
    cellstack=NULL    # DF stacking all cell properties (value ref, sheet, style...)
    databook =NULL    # List of items representing sheets and possibly ranges, where:
                      # databook$"item"$vals=   DF with item values in table format
                      # databook$"item"$styles= the same for styles, suppresed after processing styles
    rangebook=NULL    # Structure like databook, but whose item are ranges only


    
    ## Utility functions
    ## -----------------

    ## There are one or more non-null items, where empty text is considered non-null
    are=function(...) !is.null(...)
    
    ## If header true and rows>1 exclude first row
    headcut=function(df, header) {
        sel=ifelse((header && nrow(df)>1), -1, T)
        df[sel,,drop=FALSE]
    }

    ## Add header bools  to databook
    headadd=function(book, head.vec){
        Map(function(item, hashead){
            item$header=hashead
            item
        }, book, head.vec)
    }

    ## Subsetting keeping attributes
    subattr=function (df,i,j){
        a=attributes(df)
        df=df[i,j, drop=F]
        a$row.names=row.names(df)
        mostattributes(df)=a
        df
    }

    ## Convert column from letter style to numeric
    colasnum=function(s)
        sum(sapply(strsplit(s, ''), match,  LETTERS) * rep(26, nchar(s)) ^ (nchar(s):1-1))

    ## Safe error
    error=function(...){
        if(!is.null(tdir))  unlink(tdir, recursiv=T)
        stop(paste("In 'read.xlx'",  ...))
    }


        
    ## Check arguments
    ## ---------------
    
    ## Test logical arguments
    x=c(header.sheets=header.sheets, header.ranges=header.ranges, keepblanks=keepblanks)  
    xx=" argument for 'read.xlx' should be logical. Current value, "
    for(i in 1:3) if(!is.logical(x[i])) error(paste0(names(x)[i], xx, x[i], ", is not."))

    ## Test info is alone
    if(info){
        x=as.list(sys.call())[-1]
        if(length(x)!=2) error("'info' requires only file argument.")
        x=names(x)
        x=x[nzchar(x)]
        if(!all(x %in% c("file", "info"))) error("'info' requires only file argument. You passed: ", x)        
    }

    ## Test headers 
    if(is.header.ranges && is.null(uranges))
        error("'header.ranges' given without 'ranges'")
    if(is.header.sheets && is.null(usheets) && are(uranges))
        error("'header.sheets' ambiguous with 'ranges', but without 'sheets'")
    if(are(usheets) && length(header.sheets)>1 && length(header.sheets) != length(usheets))
        error("'header.sheets' and 'sheets' length differ")  
    if(are(uranges) && length(header.ranges)>1 && length(header.ranges) != length(uranges))
        error("'header.ranges' and 'ranges' length differ")
    
    ## Test "general" type
    if(!(general %in% c('character', 'numeric')))
        error("'general' can only be 'character' or 'numeric'")  
    
    ## Extract xlsx in a tmp dir
    tdir= file.path(tempdir(), "uzipx")
    dir.create(tdir, recursiv=T)
    file.copy(file, tdir)
    xlsx=file.path(tdir, basename(file))
    unzip(xlsx, exdir = tdir)
    
    
    ## Sheet and range names
    ## ---------------------
    
    ## Get names of workbook sheets
    actsheets= xmlToList(xmlParse(file.path(tdir, "xl/workbook.xml")))
    actsheets=data.frame(t(data.frame(actsheets$sheets)), stringsAsFactors = FALSE )
    rownames(actsheets) <- NULL
    actsheets$id <- gsub("\\D", "", actsheets$id)
    wbsheets=actsheets$name

    ## Check sheet header length 
    n=length(header.sheets)
    if(n>1 && length(wbsheets) !=  n && is.null(usheets))
            error("'header.sheets' and found sheets length differ")
    
    ## Check user sheets (no case)
    if(are(usheets)){
        if(!all(x<-toupper(usheets) %in% toupper(wbsheets))) 
            error(paste("unable to find sheet(s):",
                       paste(usheets[!x], collapse=", ")))
        ## usheets=actual case, names(usheets)=user case
        usheets=sapply(usheets, function(x)  wbsheets[grep(toupper(x)[1], toupper(wbsheets))])
    }
    
    ## Get range refs
    if(info || are(uranges)){
        
        ## Get names of named ranges
        xx=xmlParse(file.path(tdir, "xl/workbook.xml"))
        wbranges=xpathSApply(xx, "//x:definedName", namespaces="x", xmlGetAttr, "name")
        if(info) uranges=wbranges
        
        ## Check user ranges (no case)
        if(!all(x<-toupper(uranges) %in% toupper(wbranges))) 
            error(paste("unable to find range name(s):",
                       paste(uranges[!x], collapse=", ")))
        ## uranges=actual case, names(uranges)=user case
        uranges=sapply(uranges,
            function(x) wbranges[grep(toupper(x)[1], toupper(wbranges))])
        
        ## Load defined names and get referenced sheets
        rgrefs=sapply(uranges, function(name){
            name= paste0("//x:definedName[@name='", name, "']")
            xpathApply(xx,name, namespaces="x", xmlValue)[[1]]
        })
        names(rgrefs)=uranges #keep orginal case

        
        ## Extract referenced sheets
        rgsheets=sub( "![^!]+$", "", rgrefs)
    }

    ## Return info if required 
    if(info) {
        unlink(tdir, recursiv=T)
        return(list(wbsheets=wbsheets, rgsheets=rgsheets, rgrefs=rgrefs))
    }
 
    ## Select sheet names to process     
    ## Take the union user ranges & sheets or everything
    x=union(usheets, rgsheets)
    x=if(are(x)) {
        x=actsheets$name %in% x
        actsheets=actsheets[x,]
    }

    
    ## Extract sheet data
    ## -------------------

    ## Convert sheet names in paths
    worksheet_paths=sapply(actsheets$id, function(x) list.files(
        paste0(tdir, "/xl/worksheets"),
        full.name = TRUE,
        pattern = paste0("sheet", x, "\\.xml$")))

    ## Stack cells with attributes (value, refs, sheet) in a DF
    ## Get the "sheetData" node (with cell attribs) from each sheet
    cellstack  <- lapply(worksheet_paths, function(x) xmlRoot(xmlParse(x))[["sheetData"]])

    ## Convert each "sheetData" node in a single cellstack=
    ## DF with used cell row, val, refs, style, type, sheet
    cellstack= pblapply(seq_along(cellstack), function(i) {
        
        message(" ... Loading cells in sheet ", i)

        ## Extract cell attributes of i-th worksheet
        n=0
        cells <- xpathApply(cellstack[[i]], "//x:c", namespaces = "x", function(node) {
                n<<-n+1
                message('\r   Cell:  ', n, appendLF=FALSE)
                #cat('\r   Cell: ', n)
                c("v" = xmlValue(node[["v"]]), xmlAttrs(node))})
        
        
        ## Stack cell attributes as a dataframe
        if(length(cells) > 0) {

            message("   ... Reshaping sheet ", i )
            cells_rows <- unlist(lapply(seq_along(cells), function(i) rep(i, length(cells[[i]]))))
            cells <- unlist(cells)
            cells <- reshape(
                data.frame(
                    "row" = cells_rows,
                    "ind" = names(cells),
                    "value" = cells,
                    stringsAsFactors = FALSE),
                idvar = "row", timevar = "ind", direction = "wide")
            
            cells$sheet=actsheets$name[[i]]
            colnames(cells) <- gsub("^value\\.", "", colnames(cells))
            
        }
        cells
    })
    
    ## Stack all cell stacks in a single DF - Is commented slower? 
#####    cellstack <- do.call("rbind.fill",
#####                         cellstack[sapply(cellstack, class) == "data.frame"])
    cellstack=cellstack[sapply(cellstack, class) == "data.frame"]
    if(length(cellstack)>1) message('Aggregating sheets')
    cellstack= rbind.fill(cellstack)
    
    ## Return if whole spread is empry  
    if(is.null(cellstack)) {
        unlink(tdir, recursiv=T)
        return(NULL)  
    }
    
    ##Exclude empty/blank from act-sheets
    x=unique(cellstack$sheet)
    usheets.dirty= usheets[usheets %in% x]
    actsheets= actsheets[actsheets$name %in% x,]  
     
    ## Process shared strings & refs
    ## ------------------------------

    ## Replace cell string IDs with their actual values
    strings= xmlParse(file.path(tdir, "xl/sharedStrings.xml"))
    strings= xpathSApply(strings, "//x:si", namespaces = "x", xmlValue)
    names(strings)=seq_along(strings) - 1 #xls IDs zero based
    spos=cellstack$t == "s" & !is.na(cellstack$t)
    cellstack$v[spos] =strings[match(cellstack$v[spos], names(strings))]
    rm(strings, spos)
    ## Set 's' attribute as NA if col is  missing
    if (all("s"!=colnames(cellstack))) cellstack$s <- NA

    ## Add numeric refs to cells
    cellstack$rows=as.numeric(gsub("\\D", "", cellstack$r))
    s=gsub("\\d", "", cellstack$r)
    cellstack$cols=sapply(s, colasnum)
    
    ## Process (numeric formats in) shared styles
    ## -----------------------------------------
    ## xml-cells have a 's' attribute for style.
    ## 's' is an integer pointing to the s+1 element in the shared styles.xml->cellXfs->xf
    ## xf's have several formatting attributes. Here we care/need the numeric format ID (numFmtId)
    ## Low numFmtId's <164 (word of mouth) are built-in.
    ## Custom numFmtId's are defined in styles.xml->numFmts->numFmt via the 'formatCode' attribute    

    x=xmlParse( file.path(tdir, "xl/styles.xml"))
    ## Get num format IDs (numFmtId) 
    numfmtids = xpathApply(x, "//x:cellXfs/x:xf", namespaces = "x", xmlGetAttr, "numFmtId")
    
    ## Infer if custom num-formats (numFmt) are dates 
    custnfmts = xpathApply(x, "//x:numFmt", namespaces = "x", xmlAttrs)
    custnfmts.id=sapply(custnfmts, `[`, 'numFmtId')
    ## Replace inferred custom dates with known ids  
    codemap=sapply(custnfmts, function(x){
        f=x['formatCode']
        f=sub("^\\[\\$.+\\]", "", f) #remove locales [$...]
        d=0
        ## Time? +1
        if(grepl("h|(:m)|s", f)){
            d=d+1
            f=sub(":m+", "", f)
        }
        ## Date? +2
        if(grepl("d|m|y", f)) d=d+2
        
        ## Map to known built-in numFmtId's
        switch(as.character(d),
               "0"=x['numFmtId'], #as is
               "1"=18,            #time
               "2"=14,            #date
               "3"=22             #datetime
               )
    })
    
    ## Merge built-in and custom IDs 
    numfmtids=sapply(numfmtids, function(x) {
        xx=match(x, custnfmts.id)
        ifelse(is.na(xx), x, codemap[xx])
    })


    ## Convert cellstack in a tabular form (1 DF-table per sheet)
    ## -----------------------------------------------------------
       
    message("Formatting sheet(s) as data frames")
    databook <- lapply(unique(cellstack$sheet), function(name) {

        x=cellstack[cellstack$sheet == name,, drop=FALSE]

        ## Reshape xml sheet values 
        sheet.vals <- as.data.frame(tapply(x$v, list(x$rows, x$cols), identity),
                                    stringsAsFactors = FALSE)
        
        ## Reshape xml sheet values style ID table
        sheet.styles <- as.data.frame(tapply(x$s, list(x$rows, x$cols), identity),
                                      stringsAsFactors = FALSE)
        
        list(vals=sheet.vals, styles=sheet.styles)
    })   
    databook=setNames(databook, actsheets$name)

    ## Extract named ranges
    ## --------------------
    if(are(uranges)){
        message("Extracting named ranges")

        ## Exclude ranges in blank sheets 
        x=rgsheets %in% actsheets$name
        uranges.dirty=uranges[x]
        rgrefs=rgrefs[x]
        
        ## A1 style refs Without sheet
        refs=regmatches(rgrefs, regexpr("[^!]+$", rgrefs))
        refs=strsplit(refs, ":")
        ## Double single refs (like A1:A1)
        refs=lapply(refs, function(x) if(length(x)==1) c(x,x) else x )
        ## R1C1 style refs: missing ending col or row will be NA
        RC=list(
            r=lapply(refs, function(x) as.numeric(gsub("\\D", "", x))),    #rows
            c=lapply(refs, sapply, function(x)
                {colasnum(gsub("\\$([A-Z]+).*", "\\1", x))}, USE.NAMES=F)) #cols
        ## Map:  R1C2:R10C20->1:20,2:20; R1:R10->1:10,T ; C1:C10->T,1:10
        RC=lapply(RC, function(i){
            x=lapply(names(i), function(n)
                if(any(is.na(i[[n]])))  T else  do.call(seq, as.list( i[[n]] )))
            names(x)=uranges.dirty
            x
        })
              
        ## Calc named ranges
        rangebook=lapply(uranges.dirty, function(name) {
            r=RC$r[[name]]
            c=RC$c[[name]]
            if(!is.logical(r)) r=as.character(r[r %in% rownames(databook[[rgsheets[name]]]$vals)])
            if(!is.logical(c)) c=as.character(c[c %in%  colnames(databook[[rgsheets[name]]]$vals)])    
            list(vals=databook[[rgsheets[name]]]$vals[r,c, drop=F],
                 styles=databook[[rgsheets[name]]]$styles[r,c, drop=F])
        })

    names(rangebook)=uranges.dirty    
    }


    ## Merge sheets and range items and add header field
    ## -------------------------------------------------
    ## Blank u-sheets are returned in the end
    
    
    ## Order and select databook sheets by u-sheets
    if(are(usheets)) databook=databook[usheets.dirty]
    nams=names(databook) 


    ## Sheet headers:
    ## If header.sheets=1 recycle to act-sheets
    if(length(header.sheets)==1) header.sheets=rep(header.sheets, length(nams))
    ## If many headers: 
    else {        
        ## no u-sheets -> adapt to actual wb-sheets
        if(is.null(usheets))header.sheets=header.sheets[wbsheets %in% nams]
        ## with u-sheets -> adapt to actual u-sheets
        else header.sheets=header.sheets[usheets %in% nams]        
    }
    
    ## Range headers:
    nams=names(rangebook) 
    ## If header.ranges=1 recycle to act-ranges   
    if(length(header.ranges)==1) header.ranges=rep(header.ranges, length(nams))
    ## If many headers: adapt to act-ranges
    else header.ranges=header.ranges[uranges %in% nams]        
     
    ## Add headers to books
    databook=headadd(databook, header.sheets)
    rangebook=headadd(rangebook, header.ranges)
        
    ##With ranges, if u-sheet, merge dirty u-sheet and ranges, else range only 
    if(are(uranges))
        databook =  if(are(usheets)) c(databook, rangebook) else rangebook
    rm(rangebook) #cleanup


    
    ## Apply prevalent column style to each item (sheet/range)
    ## ------------------------------------------------------
    message("Identifying and applying prevailing styles\n")
    s=names(databook)
    databook=lapply(seq_along(databook), function(i) {

        item=databook[[i]]

        ## Store header values as an attr of value DF s       
        if(item$header && nrow(item$vals)>1) attr(item$vals, 'header')= item$vals[1,]

        ## Get prevailing styles in each item column excluding headers
        item$styles <- sapply(headcut(item$styles, item$header), function(x) {
            out <- names(which.max(table(x)))
            out[is.null(out)] <- NA
            out
        })

        ## Convert style index IDs in item$styles in num-format IDs
        if(length(numfmtids) > 0)
            item$styles= sapply(item$styles, function(x)
                ifelse(is.na(x), NA, numfmtids[[as.numeric(x)+1]]))

        ## Styles relevant to us:
        x=item$styles
        x[x %in% 9] <- "percent"
        x[x %in% 14:17] <- "date"
        x[x %in% c(18:21, 45:47)] <- "time"
        x[x %in% 22] <- "datetime"
        x[is.na(x) & !sapply(item$vals, function(x)any(grepl("\\D", x)))] <- "numeric"
        x[is.na(x)] <- general
        x[!(x %in% c("percent", "date", "time", "datetime", "numeric"))] <- "character"

        ## Allchars exluding possible different general cells
        if(allchars)  x[!(x %in% general)] <- "character"        

        item$styles=x


        ## Apply styles, but not to possible headers
        x=headcut(item$vals, item$header)
        x[] <- lapply(seq_along(x), function(i) {
            switch(item$styles[i],
                   character = x[,i],
                   numeric = as.numeric(x[,i]),
                   percent= x[,i], 
                   date = as.Date(as.numeric(x[,i]), origin = os_origin),
                   time = strftime(as.POSIXct(as.numeric(x[,i]),
                       origin = os_origin), format = "%H:%M:%S"),
                   datetime = as.POSIXct(as.numeric(x[,i]), origin = os_origin))
        })

        ## Store percent attributes as an attribute
        attr(x, "percent")= item$styles %in% "percent"
        x

    })   #end of style apply----
    names(databook)= s


    ## Pretty output
    ## ------------
    
    ## Manage blanks. Note Excel xml drops sheet blank lines
    ## If no blank wanted, drop range blanks too
    if(!keepblanks) databook=lapply(databook, function(item){
        na=is.na(item)
        r=apply(na, 1, all)
        c=apply(na, 2, all)
        subattr(item,!r, !c)  
    }) else { #Restore blank lines dropped by Excel
        addlines=function(l, col,item){
            first=ifelse(is.null(uranges), 1, l[1])
            na=first:rev(l)[1]
            na= na[!na %in% l]
            add=length(l)+1:length(na)
            o=order(as.numeric(c(l,na)))
            if(!length(na)) return(item)
            if(col)  item= `[<-`(item,,add,NA)[,o,drop=FALSE]
            else{
                rownames(item)=paste('r', l)
                item= `[<-`(item,add,,NA)[o,,drop=FALSE]
                rownames(item)=1:nrow(item)
            }
            item
        }
        
      databook=lapply(databook, function(item){
          item=addlines(l=rownames(item), col=F, item)
          item=addlines(l=colnames(item), col=T, item)
          subattr(item,T,T)
      })
    }
    
    
    ## If header, make DF colnames equal to 'header' attribute 
    databook=lapply(databook, function(item){
        if(are(attr(item, 'header'))) colnames(item)=attr(item, 'header')
        item
    })


    ## Add blank u-sheets, as data.frame()
    ## Blank items explicitly requested are returned as DF()
    nam=usheets[! usheets %in% names(databook)] # u-sheets not in databook
    x=length(nam)
    if(x) databook=c(databook,
              setNames(lapply(1:x, function(x) data.frame()), nam))
    

    ## In case of range names like sheet names this will not work
    nam=uranges[! uranges %in% names(databook)] # r-sheets not in databook
    x=length(nam)
    if(x) databook=c(databook,
              setNames(lapply(1:x, function(x) data.frame()), nam))
    
    x=c(usheets, uranges)
    if(are(x)) databook=databook[x] 
            
    ## Set user case for names
#    if(are(usheets))
#        names(databook)[seq_along(usheets)] = names(usheets)
#    if(are(uranges))
#        names(databook)[-seq_along(usheets.dirty)]

    x=c(names(usheets), names(uranges)) 
    if(are(x)) names(databook)= x
           
    ## Unembed from list if single
    if(length(databook) == 1 && simplify)  databook <- databook[[1]]
    unlink(tdir, recursiv=T)
    databook
    
}

## xlref can be a letter, an integer, an integer pair, an Excel A1 style ref.
## They are converted as follows 
## AA -> c(NA 27) Excel column as integer
## 30 -> "AD"     Excel column as letter
## c(1,1) -> A1   Excel A1-ref
## A1 ->  c(1,1)  Excel RC-ref
read.xlx.tools=function(xlref){

    ##  Num to letter
    n2l=function (x) {
        r = x %% 26
        if (x-r == 0) LETTERS[r]
        else paste0(n2l( (x-r)/16 ), LETTERS[r])    
    }

    # First element    
    # Get num and letter
    x=gsub("\\D", "", xlref[1])
    y=gsub("\\d", "", xlref[1])

    if(nzchar(y)){
        y=sum(sapply(strsplit(toupper(y), ''), match, LETTERS) *
            rep(26, nchar(y))^ (nchar(y):1-1))
        return(as.numeric(c(x, y)))
    }
    
    # Second element    
    # if no letter found, assume it is an RC pair ...
    if(length(xlref)==2) {
        y=as.numeric(gsub("\\D", "", xlref[2]))
        paste0(n2l(y), x)  # convert RC pair
    } else n2l(as.numeric(x)) # or a single integer

    
}






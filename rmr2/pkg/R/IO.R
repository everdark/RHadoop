# Copyright 2011 Revolution Analytics
#    
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
# 
#      http://www.apache.org/licenses/LICENSE-2.0
# 
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS, 
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.


make.json.input.format =
  function(key.class = rmr2:::qw(list, vector, data.frame, matrix),
           value.class = rmr2:::qw(list, vector, data.frame, matrix)) { #leave the pkg qualifier in here
    key.class = match.arg(key.class)
    value.class = match.arg(value.class)
    cast =
      function(class)
        switch(
          class,
          list = identity,
          vector = as.vector,
          data.frame = function(x) do.call(data.frame, x),
          matrix = function(x) do.call(rbind, x))
    process.field = 
      function(field, class)
        cast(class)(fromJSON(field, asText = TRUE))
    function(con, keyval.length) {
      lines = readLines(con, keyval.length)
      if (length(lines) == 0) NULL
      else {
        splits =  strsplit(lines, "\t")
        c.keyval(
          lapply(splits, 
                 function(x) 
                   if(length(x) == 1) 
                     keyval(NULL, process.field(x[1], value.class)) 
                 else 
                   keyval(process.field(x[1], key.class), process.field(x[2], value.class))))}}}

json.output.format = function(kv, con) {
  ser = function(k, v) paste(gsub("\n", "", toJSON(k, .escapeEscapes=TRUE, collapse = "")),
                             gsub("\n", "", toJSON(v, .escapeEscapes=TRUE, collapse = "")),
                             sep = "\t")
  out = apply.keyval(kv, ser, rmr.options('keyval.length'))
  writeLines(paste(out, collapse = "\n"), sep = "", con = con)}

text.input.format = function(con, keyval.length) {
  lines = readLines(con, keyval.length)
  if (length(lines) == 0) NULL
  else keyval(NULL, lines)}

text.output.format = function(kv, con) {
  ser = function(k, v) paste(k, v, collapse = "", sep = "\t")
  out = apply.keyval(kv, ser, length.keyval(kv))
  writeLines(paste(out, "\n", collapse="", sep = ""), sep = "", con = con)}

make.csv.input.format = function(...) function(con, keyval.length) {
  df = 
    tryCatch(
      read.table(file = con, nrows = keyval.length, header = FALSE, ...),
      error = function(e) NULL)
  if(is.null(df) || dim(df)[[1]] == 0) NULL
  else keyval(NULL, df)}

make.csv.output.format = function(...) function(kv, con) {
  kv = recycle.keyval(kv)
  k = keys(kv)
  v = values(kv)
  write.table(file = con, 
              x = if(is.null(k)) v else cbind(k, v), 
              ..., 
              row.names = FALSE, 
              col.names = FALSE)}

typed.bytes.reader = function(data, nobjs) {
  if(is.null(data)) NULL
  else
    .Call("typed_bytes_reader", data, nobjs, PACKAGE = "rmr2")}

typed.bytes.writer = function(objects, con, native) {
  writeBin(
    .Call("typed_bytes_writer", objects, native, PACKAGE = "rmr2"),
    con)}

make.typed.bytes.input.format = function() {
  obj.buffer = list()
  obj.buffer.rmr.length = 0
  raw.buffer = raw()
  read.size = 1000
  function(con, keyval.length) {
    while(length(obj.buffer) < 2 || 
      obj.buffer.rmr.length < keyval.length) {
      raw.buffer <<- c(raw.buffer, readBin(con, raw(), read.size))
      read.size = as.integer(2*read.size)
      if(length(raw.buffer) == 0) break;
      parsed = typed.bytes.reader(raw.buffer, as.integer(read.size/2))
      obj.buffer <<- c(obj.buffer, parsed$objects)
      obj.buffer.rmr.length <<- 
        obj.buffer.rmr.length +
        sum(sapply(sample(even(parsed$objects), 10, replace = T), rmr.length)) * length(parsed$objects) /20
      if(parsed$length != 0) raw.buffer <<- raw.buffer[-(1:parsed$length)]}
    read.size = as.integer(read.size/2)
    straddler = list()
    retval = 
      if(length(obj.buffer) == 0) NULL 
      else { 
        if(length(obj.buffer)%%2 ==1) {
           straddler = obj.buffer[length(obj.buffer)]
           obj.buffer <<- obj.buffer[-length(obj.buffer)]}
        kk = odd(obj.buffer)
        vv = even(obj.buffer)
        kk = 
          inverse.rle(
            list(
              lengths = sapply(vv, rmr.length),
              values = kk))
        keyval(
          c.or.rbind(kk),
          c.or.rbind(vv))}
    obj.buffer <<- straddler
    obj.buffer.rmr.length <<- 0
    retval}}
  
make.native.input.format = make.typed.bytes.input.format

make.native.or.typedbytes.output.format = 
  function(keyval.length, native)
    function(kv, con){
      kvs = split.keyval(kv, keyval.length)
      typed.bytes.writer(interleave(keys(kvs), values(kvs)), con, native)}

make.native.output.format = Curry(make.native.or.typedbytes.output.format, native = TRUE)
make.typedbytes.output.format = Curry(make.native.or.typedbytes.output.format, native = FALSE)

# I/O 

make.keyval.reader = function(mode, format, keyval.length, con = NULL) {
  if(mode == "text") {
    if(is.null(con)) con = file("stdin", "r")} #not stdin() which is parsed by the interpreter
  else {
    if(is.null(con)) con = pipe("cat", "rb")}
  function() 
    format(con, keyval.length)}

make.keyval.writer = function(mode, format, con = NULL) {
  if(mode == "text") {
    if(is.null(con)) con = stdout()}
  else {
    if(is.null(con)) con = pipe("cat", "wb")}
  function(kv) format(kv, con)}

IO.formats = c("text", "json", "csv", "native",
               "sequence.typedbytes")

make.input.format = 
  function(
    format = make.native.input.format(), 
    mode = c("binary", "text"),
    streaming.format = NULL, 
    ...) {
    mode = match.arg(mode)
    if(is.character(format)) {
      format = match.arg(format, IO.formats)
      switch(
        format, 
        text = {
          format = text.input.format 
          mode = "text"}, 
        json = {
          format = make.json.input.format(...) 
          mode = "text"}, 
        csv = {
          format = make.csv.input.format(...) 
          mode = "text"}, 
        native = {
          format = make.native.input.format() 
          mode = "binary"}, 
        sequence.typedbytes = {
          format = make.typed.bytes.input.format() 
          mode = "binary"})}
    if(is.null(streaming.format) && mode == "binary") 
      streaming.format = "org.apache.hadoop.streaming.AutoInputFormat"
    list(mode = mode, format = format, streaming.format = streaming.format)}

make.output.format = 
  function(
    format = make.native.output.format(keyval.length = rmr.options('keyval.length')),
    mode = c("binary", "text"),
    streaming.format = "org.apache.hadoop.mapred.SequenceFileOutputFormat", 
    ...) {
    mode = match.arg(mode)
    if(is.character(format)) {
      format = match.arg(format, IO.formats)
      switch(
        format, 
        text = {
          format = text.output.format
          mode = "text"
          streaming.format = NULL},
        json = {
          format = json.output.format
          mode = "text"
          streaming.format = NULL}, 
        csv = {
          format = make.csv.output.format(...)
          mode = "text"
          streaming.format = NULL}, 
        native = {
          format = make.native.output.format(
            keyval.length = rmr.options('keyval.length'))
          mode = "binary"
          streaming.format = "org.apache.hadoop.mapred.SequenceFileOutputFormat"}, 
        sequence.typedbytes = {
          format = make.native.output.format(keyval.length = rmr.options('keyval.length'))
          mode = "binary"
          streaming.format = "org.apache.hadoop.mapred.SequenceFileOutputFormat"})}
    mode = match.arg(mode)
    list(mode = mode, format = format, streaming.format = streaming.format)}
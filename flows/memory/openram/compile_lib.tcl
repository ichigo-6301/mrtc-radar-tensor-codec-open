proc require_env {name} {
  if {![info exists ::env($name)] || $::env($name) eq ""} {
    error "Missing required environment variable: $name"
  }
  return $::env($name)
}

set liberty_path [require_env RDTC_SRAM_LIB]
set library_name [require_env RDTC_SRAM_LIB_NAME]
set db_path [require_env RDTC_SRAM_DB]

if {[catch {read_lib $liberty_path} read_message]} {
  error "OpenRAM Liberty read failed: $read_message"
}
if {[catch {write_lib $library_name -format db -output $db_path} write_message]} {
  error "OpenRAM DB write failed: $write_message"
}
if {![file isfile $db_path]} {
  error "Library Compiler did not create $db_path"
}
puts "INFO: compiled $liberty_path to $db_path"
quit

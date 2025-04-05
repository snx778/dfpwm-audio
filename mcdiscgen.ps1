param(
	[Parameter(Mandatory=$true, Position=0)]
	[string]$in_dir_audios,

	[Parameter(Mandatory=$true)]
	[string]$name_of_pack,

	[Parameter(Mandatory=$true)]
	[string]$covers_dir,

	[Parameter(Mandatory=$false)]
	[string]$out_dir_project = "mdiscgen-project",

	[Parameter(Mandatory=$false)]
	[string]$description_of_pack = "Custom music discs.",

	[Parameter(Mandatory=$false)]
	[string]$logo_icon_path,

	[Parameter(Mandatory=$false)]
	[ValidatePattern('^\d+[kKmM]?$')]
	[string]$bitrate = "80k",

	[Parameter(Mandatory=$false)]
	[ValidateRange(8000, 192000)]
	[int]$samplerate = 44100,

	[switch]$archived,
	
	[switch]$force,
	
	# Hack: $true is set in a subsequent call
	# ( the script is started in a new shell 
	# to prevent any global variables overrides )
	[switch]$fork
)


### Script forking
if (-not $fork) {
	$argList = @($PSCommandPath, "-fork") # Important: do not remove -fork
	
	foreach ($kvp in $PSBoundParameters.GetEnumerator()) {
		$name = "-$($kvp.Key)"
		$value = $kvp.Value
		if ($value -is [switch]) {
			if ($value.IsPresent) { $argList += $name }
		} else {
			$argList += @($name, "$value")
		}
	}
	
	pwsh @argList 
	return
}

### Powershell enforcements
$ErrorActionPreference = "Stop"
$WarningPreference = "Stop"
$ErrorView = 'DetailedView'
[System.IO.Directory]::SetCurrentDirectory($pwd)

### Function declarations
function Get-Base26 {
	param([long]$number); $rem = 0; $txt = ""; $sign = ""
	if ($number -lt 0) {
		$sign = "-"
		$number = -$number
	}
	do {
		$tmp = [Math]::DivRem($number, 26)
		$number = $tmp[0]; $rem = $tmp[1]
		$txt = "abcdefghijklmnopqrstuvwxyz"[$rem] + $txt
	} while ($number -ne 0)

	return $sign + $txt
}

filter Escape-NonASCII {
	$sb = [System.Text.StringBuilder]::new()
	foreach ($char in $_.GetEnumerator()) {
		if ([int]$char -gt 127) {
			$null = $sb.AppendFormat("\u{0:X4}", [int]$char)
		} else {
			$null = $sb.Append($char)
		}
	}
	$sb.ToString()
}

filter To-Json {
	$_ | ConvertTo-Json -Depth 10
}

filter From-Json {
	$_ | ConvertFrom-Json -AsHashtable
}

function Get-SHA1 {
	param([string]$file)
	$hash = Get-FileHash -Algorithm SHA1 -LiteralPath $file
	if ($hash) {
		return $hash.Hash.ToLowerInvariant()
	}
}

function Safe-Join {
	foreach ($arg in $args) {
		if ([string]::IsNullOrEmpty($arg)) {
			throw "Path contains null or empty parts."
		}
		if ($arg.GetType() -ne [string]) {
			throw "List contains non-string parameters."
		}
	}
	return Join-Path @args
}

function Exists {
	foreach ($arg in $args) {
		if ([string]::IsNullOrEmpty($arg)) {
			throw "List contains null or empty paths."
		}
		if ($arg.GetType() -ne [string]) {
			throw "List contains non-string parameters."
		}
		if (-not (Test-Path -LiteralPath $arg)) {
			return $false
		}
		return $true
	}
}

function Update-Cache {
	param($all_lookup, $files_seen, $factory)
	process {
		$hash = (Get-FileHash -Algorithm SHA512 -LiteralPath $_).Hash.ToLowerInvariant()
		$files_seen[$hash] = $true
		if (-not $all_lookup[$hash]) {
			$all_lookup[$hash] = (& $factory $_ $hash)
		}
	}
}

function Clean-Outdated-Cache {
	param($all_lookup, $files_seen, $action)
	foreach ($kvp in $all_lookup.Clone().GetEnumerator()) {
		$hash = $kvp.Key
		$meta = $kvp.Value
		$path = Safe-Join $cache_dir $hash
		if (-not $files_seen[$hash]) {
			if ((& $action $hash $meta) -eq $true) {
				$all_lookup.Remove($hash)
			}
		}
	}
}


### Variable declarations
$data_haschanged	= $false
$cache_dir 			= Safe-Join $out_dir_project ".cache"

$ffmpeg_dir			= Safe-Join $cache_dir "ffmpeg-bin"
$env:PATH 			= "$ffmpeg_dir;$env:PATH"

$cache_music_ids	= Safe-Join $cache_dir "music-ids.json"
$cache_dir_audio	= Safe-Join $cache_dir "audio"
$cache_dir_covers	= Safe-Join $cache_dir "covers"

$rp					= Safe-Join $out_dir_project "$name_of_pack`_rp"
$rp_items			= Safe-Join $rp "assets/$name_of_pack/items"
$rp_models_item		= Safe-Join $rp "assets/$name_of_pack/models/item"
$rp_sounds_records	= Safe-Join $rp "assets/$name_of_pack/sounds/records"
$rp_textures_item	= Safe-Join $rp "assets/$name_of_pack/textures/item"

$mcrp_atlases		= Safe-Join $rp "assets/minecraft/atlases"
$mcrp_models_item	= Safe-Join $rp "assets/minecraft/models/item"

$dp					= Safe-Join $out_dir_project "$name_of_pack`_dp"
$dp_function		= Safe-Join $dp "data/$name_of_pack/function"
$dp_function_give	= Safe-Join $dp "data/$name_of_pack/function/give"
$dp_jukebox_song	= Safe-Join $dp "data/$name_of_pack/jukebox_song"

$mcdp_loot_table_entities = Safe-Join $dp "data/minecraft/loot_table/entities"

$rp_zip				= "$rp.zip"
$dp_zip				= "$dp.zip"


### Prepare project directory
New-Item -Path $cache_dir_audio		-ItemType Directory -Force | Out-Null
New-Item -Path $cache_dir_covers	-ItemType Directory -Force | Out-Null


### Download ffmpeg if not found
if (-not (Get-Command ffmpeg -ErrorAction SilentlyContinue)) {
	Write-Host "### Downloading the latest version of ffmpeg"
	$ffmpeg_zip = Safe-Join $cache_dir "ffmpeg-latest.zip"
	$ffmpeg_dir_tmp = Safe-Join $cache_dir "ffmpeg-latest.tmp"
	$api_url = "https://api.github.com/repos/GyanD/codexffmpeg/releases/latest"
	$download_url = (Invoke-RestMethod -Uri $api_url).assets |
		Where-Object { $_.name -like "*-essentials_build.zip" } |
		Select-Object -First 1 -ExpandProperty browser_download_url
	Invoke-WebRequest $download_url -OutFile $ffmpeg_zip
	Expand-Archive -LiteralPath $ffmpeg_zip -DestinationPath $ffmpeg_dir_tmp
	$ffmpeg_version_name = [System.IO.Path]::
		GetFileNameWithoutExtension(
		[System.Uri]::new($download_url).AbsolutePath
	)
	$ffmpeg_tmp_bin = Safe-Join $ffmpeg_dir_tmp $ffmpeg_version_name "bin"
	Move-Item $ffmpeg_tmp_bin -Destination $ffmpeg_dir
	Remove-Item -ErrorAction SilentlyContinue -LiteralPath $ffmpeg_zip
	Remove-Item -Recurse -ErrorAction SilentlyContinue -LiteralPath $ffmpeg_dir_tmp
}


### Load configs from cache
$PROJ_CFG = $null
try {
	$PROJ_CFG = Get-Content $cache_music_ids -Raw | From-Json
} catch {
	$PROJ_CFG = @{
		last_id = -1
		last_id_cover = -1
		files = @{}
		covers = @{}
	}
}


### Hardcoded resourcepack json files
$json_rp_mcmeta = @{
	pack = @{
		pack_format = 46
		description = $description_of_pack
	}
}
$json_rp_atlases_blocks = @{
	sources = @(
		@{
			type = "directory"
			source = "item"
			prefix = "item/"
		}
	)
}
$json_rp_music_disc_11 = @{
	parent = "item/generated"
	textures = @{
		layer0 = "item/music_disc_11"
	}
	overrides = @()
}
$json_rp_all_sounds = @{}


### Hardcoded datapack json files
$json_dp_tags_function = @{
	values = @(
		"$name_of_pack`:setup_load"
	)
}
$json_dp_mcmeta = @{
	pack = @{
		pack_format = 61
		description = $description_of_pack
	}
}
$json_dp_loot_table_creeper_custom_pool = @{
	rolls = 1
	entries = @(
		@{
			type = "minecraft:tag"
			weight = 1
			name = "minecraft:creeper_drop_music_discs"
			expand = $true
		}
	)
	conditions = @(
		@{
			condition = "minecraft:entity_properties"
			predicate = @{
				type = "#minecraft:skeletons"
			}
			entity = "attacker"
		}
	)
}
$json_dp_loot_table_creeper_default_pool = @{
	rolls = 1
	entries = @(
		@{
			type = "minecraft:item"
			functions = @(
				@{
					add = $false
					count = @{
						type = "minecraft:uniform"
						max = 2.0
						min = 0.0
					}
					function = "minecraft:set_count"
				},
				@{
					count = @{
						type = "minecraft:uniform"
						max = 1.0
						min = 0.0
					}
					enchantment = "minecraft:looting"
					function = "minecraft:enchanted_count_increase"
				}
			)
			name = "minecraft:gunpowder"
		}
	)
}
$json_dp_loot_table_creeper = @{
	type = "minecraft:entity"
	random_sequence = "minecraft:entities/creeper"
	pools = @(
		$json_dp_loot_table_creeper_default_pool,
		$json_dp_loot_table_creeper_custom_pool
	)
}


### Update cover cache
Write-Host "### Updating cache indices for the covers"
$covers_seen = @{}
Get-ChildItem -File -LiteralPath $covers_dir -Filter "*.png" |
	Update-Cache $PROJ_CFG.covers $covers_seen {
		param($src_file, $sha512)
		
		Write-Host "New cover `"$src_file`""
		Copy-Item $src_file (Safe-Join $cache_dir_covers $sha512)
		$PROJ_CFG.last_id_cover += 1
		
		return @{
			id = $PROJ_CFG.last_id_cover
			name = "img_" + (Get-Base26 $PROJ_CFG.last_id_cover)
		}
	}


### Update audio cache
Write-Host "### Updating cache indices for the tracks"
$tracks_seen = @{}
Get-ChildItem -File -LiteralPath $in_dir_audios |
	Where-Object { $_.Extension -in ".mp3", ".m4a", ".ogg", ".wav", ".webm" } |
	Update-Cache $PROJ_CFG.files $tracks_seen {
		param($src_file, $sha512)
		
		$data_haschanged = $true
		$dst_file = Safe-Join $cache_dir_audio $sha512
		$ffmpeg_args = @(
			"-y", 
			"-loglevel", "error",
			"-i", $src_file,
			"-c:a", "libvorbis",
			"-b:a", $bitrate, 
			"-ar", $samplerate, 
			"-map_metadata", "-1",
			"-vn", 
			"-ac", 1,
			"-f", "ogg"
			$dst_file
		)
		$ffprobe_args = @(
			"-i", $dst_file,
			"-show_entries", "format=duration",
			"-v", "quiet", 
			"-of", "csv=p=0"
		)
		
		if (-not (Exists $dst_file)) {
			ffmpeg @ffmpeg_args
		} else {
			$LASTEXITCODE = 0
		}
		$duration_secs = [float](ffprobe @ffprobe_args)
		
		
		if (($LASTEXITCODE -ne 0) -or ($duration_secs -eq 0)) {
			ffmpeg @ffmpeg_args
			$duration_secs = [float](ffprobe @ffprobe_args)
		}
		
		if ($LASTEXITCODE -eq 0) {
			$PROJ_CFG.last_id += 1
			$mus_name = "mus_" + (Get-Base26 $PROJ_CFG.last_id)
			
			Write-Host "Cached `"$src_file`" as `"$mus_name`""
			return @{
				id = $PROJ_CFG.last_id
				name = $mus_name
				texture = (@($PROJ_CFG.covers.Values))[[Random]::Shared.Next(0, $PROJ_CFG.covers.Count)].name
				duration = $duration_secs
				description = $_.BaseName
			}
		}
		
		Remove-Item -LiteralPath $dst_file -ErrorAction SilentlyContinue
		Write-Host "Failed to cache `"$src_file`""
	}
Clean-Outdated-Cache $PROJ_CFG.files $tracks_seen {
	param($sha512, $meta)
	
	$data_haschanged = $true
	$dst_file = Safe-Join $cache_dir_audio $sha512
	Remove-Item -LiteralPath $dst_file -ErrorAction SilentlyContinue
	Write-Host "Removed `"$($meta.name)`" from cache"
	return $true
}


### Save cached indices
$PROJ_CFG | To-Json > $cache_music_ids

### Incremental updates check
$data_haschanged = $force -or $data_haschanged -or
	($archived -and (-not (Exists $rp_zip $dp_zip)))

if (-not $data_haschanged) {
	Write-Host "### All packs are up-to-date."
	return
} else {
	Write-Host "### Deleting old packs"
	Remove-Item -ErrorAction SilentlyContinue -LiteralPath $rp_zip
	Remove-Item -ErrorAction SilentlyContinue -LiteralPath $dp_zip
	Remove-Item -ErrorAction SilentlyContinue -LiteralPath $dp		-Recurse
	Remove-Item -ErrorAction SilentlyContinue -LiteralPath $rp		-Recurse
}


### Re-create packs structure
New-Item -Path $rp_items			-ItemType Directory -Force | Out-Null
New-Item -Path $rp_models_item		-ItemType Directory -Force | Out-Null
New-Item -Path $rp_sounds_records	-ItemType Directory -Force | Out-Null
New-Item -Path $rp_textures_item	-ItemType Directory -Force | Out-Null
New-Item -Path $mcrp_atlases		-ItemType Directory -Force | Out-Null
New-Item -Path $mcrp_models_item	-ItemType Directory -Force | Out-Null
New-Item -Path $dp					-ItemType Directory -Force | Out-Null
New-Item -Path $dp_function			-ItemType Directory -Force | Out-Null
New-Item -Path $dp_function_give	-ItemType Directory -Force | Out-Null
New-Item -Path $dp_jukebox_song		-ItemType Directory -Force | Out-Null
New-Item -Path $mcdp_loot_table_entities `
									-ItemType Directory -Force | Out-Null


### Generate resourcepack
Write-Host "### Generating resourcepack files"

foreach ($file_kvp in $PROJ_CFG.files.GetEnumerator()) {
	$file_path = Safe-Join $cache_dir_audio $file_kvp.Key
	$meta = $file_kvp.Value
	$meta_name = $meta.name
	$json_file_name =  "$meta_name.json"
	$ogg_file_name = "$meta_name.ogg"
	$item_name = "$name_of_pack`:item/$meta_name"

	$json_rp_all_sounds["music_disc." + $meta.name] = @{
		sounds = @(
			@{
				name = "$name_of_pack`:records/$meta_name"
				stream = $true
			}
		)
	}
	
	@{
		parent = "item/generated"
		textures = @{
			layer0 = "$name_of_pack`:item/" + $meta.texture
		}
	} | To-Json > (Safe-Join $rp_models_item $json_file_name)

	@{
		model = @{
			type = "minecraft:model"
			model = $item_name
		}
	} | To-Json > (Safe-Join $rp_items $json_file_name)

	$json_rp_music_disc_11.overrides += @{
		predicate = @{
			custom_model_data = $meta.id
		}
		model = $item_name
	}

	Copy-Item $file_path -Destination (Safe-Join $rp_sounds_records $ogg_file_name)
}

foreach ($cover_kvp in $PROJ_CFG.covers.GetEnumerator()) {
	$meta = $cover_kvp.Value
	$src_file = Safe-Join $cache_dir_covers $cover_kvp.Key
	$dst_file = Safe-Join $rp_textures_item "$($meta.name).png"
	Copy-Item $src_file -Destination $dst_file
}

if ($logo_icon_path) {
	Copy-Item $logo_icon_path -Destination (Safe-Join $rp "pack.png")
	Copy-Item $logo_icon_path -Destination (Safe-Join $dp "pack.png")
}
$json_rp_mcmeta			| To-Json > (Safe-Join $rp "pack.mcmeta")
$json_rp_atlases_blocks	| To-Json > (Safe-Join $mcrp_atlases "blocks.json")
$json_rp_music_disc_11	| To-Json > (Safe-Join $mcrp_models_item "music_disc_11.json")
$json_rp_all_sounds		| To-Json > (Safe-Join $rp "assets/$name_of_pack/sounds.json")


### Generate datapack
Write-Host "### Generating datapack files"

$give_all_txt = ""
foreach ($file_kvp in $PROJ_CFG.files.GetEnumerator()) {
	$file = $file_kvp.Value
	$key = $file.name
	$item_name = "$name_of_pack`:" + $file.name
	$sound_id = "$name_of_pack`:music_disc." + $file.name

	$json_dp_loot_table_creeper_custom_pool.entries += @{
		type = "minecraft:item"
		weight = 1
		name = "minecraft:music_disc_11"
		functions = @(
			@{
				function = "minecraft:set_components"
				components = @{
					"minecraft:item_model" = $item_name
					"minecraft:jukebox_playable" = @{
						song = $item_name
					}
				}
			}
		)
	}
	
	@{
		comparator_output = 11
		description = $file.description
		length_in_seconds = $file.duration
		sound_event = @{
			sound_id = $sound_id
			range = 64.0
		}
	} | To-Json | Escape-NonASCII > (Safe-Join $dp_jukebox_song "$key.json")
	
	"execute at @s run summon item ~ ~ ~ " +
		"{Item:{id:`"minecraft:music_disc_11`", Count:1b, " +
		"components:{`"minecraft:item_model`":`"$item_name`", " +
		"`"minecraft:jukebox_playable`":{song:`"$item_name`"}}}}" > `
		(Safe-Join $dp_function_give "$key.mcfunction")
		
	$give_all_txt += "execute at @s run function $name_of_pack`:give/$key`n"
}

$give_all_txt							> (Safe-Join $dp_function "give_all_discs.mcfunction")
$json_dp_mcmeta				| To-Json	> (Safe-Join $dp "pack.mcmeta")
$json_dp_loot_table_creeper	| To-Json	> (Safe-Join $mcdp_loot_table_entities "creeper.json")

if ($archived) {
	Write-Host "### Generating .zip files"
	Compress-Archive -LiteralPath (Get-ChildItem $rp) -CompressionLevel Optimal -DestinationPath $rp_zip
	Compress-Archive -LiteralPath (Get-ChildItem $dp) -CompressionLevel Optimal -DestinationPath $dp_zip
	Get-SHA1 -File $rp_zip > "$rp_zip.sha1"
}

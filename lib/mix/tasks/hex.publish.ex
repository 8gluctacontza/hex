defmodule Mix.Tasks.Hex.Publish do
  use Mix.Task
  alias Mix.Tasks.Hex.Build

  @shortdoc "Publishes a new package version"

  @moduledoc """
  Publishes a new version of the package.

      $ mix hex.publish

  The current authenticated user will be the package owner. Only package
  owners can publish the package, new owners can be added with the
  `mix hex.owner` task.

  Packages and documentation sizes are limited to 8mb compressed, and 64mb uncompressed.

  ## Publishing documentation

  Documentation will be generated by running the `mix docs` task. `ex_doc`
  provides this task by default, but any library can be used. Or an alias can be
  used to extend the documentation generation. The expected result of the task
  is the generated documentation located in the `doc/` directory with an
  `index.html` file.

  The documentation will be accessible at `https://hexdocs.pm/my_package/1.0.0`,
  `https://hexdocs.pm/my_package` will always redirect to the latest published
  version.

  Documentation will be built and published automatically. To publish a package
  without documentation run `mix hex.publish package` or to only publish documentation
  run `mix hex.publish docs`.

  ## Reverting a package

  A new package can be reverted or updated within 24 hours of it's initial publish,
  a new version of an existing package can be reverted or updated within one hour.
  Documentation have no limitations on when it can be updated.

  To update the package simply run the `mix hex.publish` task again. To revert run
  `mix hex.publish --revert VERSION` or to only revert the documentation run
  `mix hex.publish docs --revert VERSION`.

  If the last version is reverted, the package is removed.

  ## Command line options

    * `--organization ORGANIZATION` - Set this for private packages belonging to an organization
    * `--yes` - Publishes the package without any confirmation prompts
    * `--dry-run` - Builds package and performs local checks without publishing,
      use `mix hex.build --unpack` to inspect package contents before publishing
    * `--replace` - Allows overwriting an existing package version if it exists.
      Private packages can always be overwritten, public packages can only be
      overwritten within one hour after they were initially published.
    * `--revert VERSION` - Revert given version. If the last version is reverted,
      the package is removed.

  #{Hex.Package.configuration_doc()}
  """
  @behaviour Hex.Mix.TaskDescription

  @switches [
    revert: :string,
    progress: :boolean,
    organization: :string,
    organisation: :string,
    yes: :boolean,
    dry_run: :boolean,
    replace: :boolean
  ]

  @impl true
  def run(args) do
    Mix.Tasks.Deps.Loadpaths.run(["--no-compile"])
    Hex.start()
    {opts, args} = OptionParser.parse!(args, strict: @switches)

    build = Build.prepare_package()
    revert_version = opts[:revert]
    revert = !!revert_version
    organization = opts[:organization] || build.organization

    case args do
      ["package"] when revert ->
        auth = Mix.Tasks.Hex.auth_info(:write)
        revert_package(build, organization, revert_version, auth)

      ["docs"] when revert ->
        auth = Mix.Tasks.Hex.auth_info(:write)
        revert_docs(build, organization, revert_version, auth)

      [] when revert ->
        auth = Mix.Tasks.Hex.auth_info(:write)
        revert_package(build, organization, revert_version, auth)

      ["package"] ->
        case proceed_with_owner(build, organization, opts) do
          {:ok, owner} ->
            auth = Mix.Tasks.Hex.auth_info(:write)
            Hex.Shell.info("Publishing package...")

            case create_release(build, organization, auth, opts) do
              :ok -> transfer_owner(build, owner, auth, opts)
              _ -> Mix.Tasks.Hex.set_exit_code(1)
            end

          :error ->
            :ok
        end

      ["docs"] ->
        docs_task()
        auth = Mix.Tasks.Hex.auth_info(:write)
        create_docs(build, organization, auth, opts)

      [] ->
        create(build, organization, opts)

      _ ->
        Mix.raise("""
        Invalid arguments, expected one of:

        mix hex.publish
        mix hex.publish package
        mix hex.publish docs
        """)
    end
  end

  @impl true
  def tasks() do
    [
      {"", "Publishes a new package version"},
      {"package", "Publish current package"},
      {"docs", "Publish current docs"},
      {"package --revert VERSION", "Reverts package on given version"},
      {"docs --revert VERSION", "Reverts docs on given version"},
      {"--revert VERSION", "Reverts given version"}
    ]
  end

  defp create(build, organization, opts) do
    case proceed_with_owner(build, organization, opts) do
      {:ok, owner} ->
        Hex.Shell.info("Building docs...")
        docs_task()
        auth = Mix.Tasks.Hex.auth_info(:write)
        Hex.Shell.info("Publishing package...")

        case create_release(build, organization, auth, opts) do
          :ok ->
            Hex.Shell.info("Publishing docs...")
            create_docs(build, organization, auth, opts)
            transfer_owner(build, owner, auth, opts)

          _ ->
            Mix.Tasks.Hex.set_exit_code(1)
        end

      :error ->
        :ok
    end
  end

  defp create_docs(build, organization, auth, opts) do
    directory = docs_dir()
    name = build.meta.name
    version = build.meta.version

    unless File.exists?("#{directory}/index.html") do
      Mix.raise("File not found: #{directory}/index.html")
    end

    progress? = Keyword.get(opts, :progress, true)
    dry_run? = Keyword.get(opts, :dry_run, false)
    tarball = build_docs_tarball(directory)

    if dry_run? do
      :ok
    else
      send_tarball(organization, name, version, tarball, auth, progress?)
    end
  end

  defp docs_task() do
    # Elixir v1.15 prunes the loadpaths on compilation and
    # docs will compile code. So we add all original code paths back.
    path = :code.get_path()

    try do
      Mix.Task.run("docs", [])
    rescue
      ex in [Mix.NoTaskError] ->
        require Hex.Stdlib
        stacktrace = Hex.Stdlib.stacktrace()

        Mix.shell().error("""
        Publication failed because the "docs" task is unavailable. You may resolve this by:

          1. Adding {:ex_doc, ">= 0.0.0", only: :dev, runtime: false} to your dependencies in your mix.exs and trying again
          2. If ex_doc was already added, make sure you run "mix hex.publish" in the same environment as the ex_doc package
          3. Publishing the package without docs by running "mix hex.publish package" (not recommended)
        """)

        reraise ex, stacktrace
    after
      :code.add_pathsz(path)
    end
  end

  defp proceed_with_owner(build, organization, opts) do
    meta = build.meta
    exclude_deps = build.exclude_deps
    package = build.package

    Hex.Shell.info("Building #{meta.name} #{meta.version}")
    Build.print_info(meta, organization, exclude_deps, package[:files])

    print_link_to_coc()
    print_public_private(organization)
    print_owner_prompt(build, organization, opts)
  end

  defp print_public_private(organization) do
    api_url = Hex.State.fetch!(:api_url)
    default_api_url? = api_url == Hex.State.default_api_url()

    using_api =
      if default_api_url? do
        ""
      else
        " using #{api_url}"
      end

    to_repository =
      cond do
        !organization and !default_api_url? ->
          ""

        public_organization?(organization) ->
          [" to ", :bright, "public", :reset, " repository hexpm"]

        true ->
          [" to ", :bright, "private", :reset, " repository #{organization}"]
      end

    Hex.Shell.info(
      Hex.Shell.format([
        "Publishing package",
        to_repository,
        using_api,
        "."
      ])
    )
  end

  defp print_owner_prompt(build, organization, opts) do
    auth = Mix.Tasks.Hex.auth_info(:read)
    organizations = user_organizations(auth)

    owner_prompt? =
      public_organization?(organization) and
        not Keyword.get(opts, :yes, false) and
        organizations != [] and
        not package_exists?(build)

    Hex.Shell.info("")

    if owner_prompt? do
      do_print_owner_prompt(organizations)
    else
      if Keyword.get(opts, :yes, false) or Hex.Shell.yes?("Proceed?") do
        {:ok, nil}
      else
        :error
      end
    end
  end

  defp do_print_owner_prompt(organizations) do
    Hex.Shell.info(
      "You are a member of one or multiple organizations. Would you like to publish " <>
        "the package with yourself as owner or an organization as owner? " <>
        "If you publish with an organization as owner your package will " <>
        "be public but managed by the selected organization."
    )

    Hex.Shell.info("")
    Hex.Shell.info("  [1] Yourself")

    numbers = Stream.map(Stream.iterate(2, &(&1 + 1)), &Integer.to_string/1)
    organizations = Stream.zip(numbers, organizations)

    Enum.each(organizations, fn {ix, organization} ->
      Hex.Shell.info("  [#{ix}] #{organization}")
    end)

    Hex.Shell.info("")
    owner_prompt_selection(Map.new(organizations))
  end

  defp owner_prompt_selection(organizations) do
    selection = String.trim(Hex.Shell.prompt("Your selection:"))

    if selection == "1" do
      {:ok, nil}
    else
      case Map.fetch(organizations, selection) do
        {:ok, organization} -> {:ok, organization}
        :error -> owner_prompt_selection(organizations)
      end
    end
  end

  defp package_exists?(build) do
    case Hex.API.Package.get("hexpm", build.meta.name) do
      {:ok, {200, _body, _headers}} ->
        true

      {:ok, {404, _body, _headers}} ->
        false

      other ->
        Hex.Utils.print_error_result(other)
        true
    end
  end

  defp user_organizations(auth) do
    case Hex.API.User.me(auth) do
      {:ok, {200, body, _header}} ->
        Enum.map(body["organizations"], & &1["name"])

      other ->
        Hex.Utils.print_error_result(other)
        []
    end
  end

  defp public_organization?(organization), do: organization in [nil, "hexpm"]

  defp transfer_owner(_build, nil, _auth, _opts) do
    :ok
  end

  defp transfer_owner(build, owner, auth, opts) do
    Hex.Shell.info("Transferring ownership to #{owner}...")
    dry_run? = Keyword.get(opts, :dry_run, false)

    if dry_run? do
      :ok
    else
      case Hex.API.Package.Owner.add("hexpm", build.meta.name, owner, "full", true, auth) do
        {:ok, {status, _body, _header}} when status in 200..299 ->
          :ok

        other ->
          Hex.Shell.error("Failed to transfer ownership")
          Hex.Utils.print_error_result(other)
      end
    end
  end

  defp print_link_to_coc() do
    Hex.Shell.info(
      "Before publishing, please read the Code of Conduct: " <>
        "https://hex.pm/policies/codeofconduct\n"
    )
  end

  defp revert_package(build, organization, version, auth) do
    name = build.meta.name

    case Hex.API.Release.delete(organization, name, version, auth) do
      {:ok, {code, _, _}} when code in 200..299 ->
        Hex.Shell.info("Reverted #{name} #{version}")

      other ->
        Hex.Shell.error("Reverting #{name} #{version} failed")
        Hex.Utils.print_error_result(other)
    end
  end

  defp revert_docs(build, organization, version, auth) do
    name = build.meta.name

    case Hex.API.ReleaseDocs.delete(organization, name, version, auth) do
      {:ok, {code, _, _}} when code in 200..299 ->
        Hex.Shell.info("Reverted docs for #{name} #{version}")

      {:ok, {404, _, _}} ->
        Hex.Shell.info("Docs do not exist")

      other ->
        Hex.Shell.error("Reverting docs for #{name} #{version} failed")
        Hex.Utils.print_error_result(other)
    end
  end

  defp build_docs_tarball(directory) do
    files = files(directory)
    raise_if_file_matches_semver(files)
    {:ok, data} = :mix_hex_tarball.create_docs(files)
    data
  end

  defp raise_if_file_matches_semver(files) do
    Enum.map(files, fn
      {filename, _contents} -> filename_matches_semver!(filename)
      filename -> filename_matches_semver!(filename)
    end)
  end

  defp filename_matches_semver!(filename) do
    top_level = filename |> Path.split() |> List.first()

    case Version.parse(to_string(top_level)) do
      {:ok, _struct} ->
        Mix.raise("Invalid filename: top-level filenames cannot match a semantic version pattern")

      _ ->
        :ok
    end
  end

  defp send_tarball(organization, name, version, tarball, auth, progress?) do
    progress = progress_fun(progress?, byte_size(tarball))

    case Hex.API.ReleaseDocs.publish(organization, name, version, tarball, auth, progress) do
      {:ok, {code, _body, headers}} when code in 200..299 ->
        api_url = Hex.State.fetch!(:api_url)
        default_api_url? = api_url == Hex.State.default_api_url()

        location =
          if !default_api_url? && headers["location"] do
            headers["location"]
          else
            Hex.Utils.hexdocs_url(organization, name, version)
          end

        Hex.Shell.info("")
        Hex.Shell.info(["Docs published to ", location])
        :ok

      {:ok, {404, _, _}} ->
        Hex.Shell.info("")
        Hex.Shell.error("Publishing docs failed due to the package not being published yet")
        :error

      other ->
        Hex.Shell.info("")
        Hex.Shell.error("Publishing docs failed")
        Hex.Utils.print_error_result(other)
        :error
    end
  end

  defp files(directory) do
    "#{directory}/**"
    |> Path.wildcard()
    |> Enum.filter(&File.regular?/1)
    |> Enum.map(&{relative_path(&1, directory), File.read!(&1)})
  end

  defp relative_path(file, dir) do
    Path.relative_to(file, dir)
    |> String.to_charlist()
  end

  defp docs_dir do
    cond do
      File.exists?("doc") ->
        "doc"

      File.exists?("docs") ->
        "docs"

      true ->
        Mix.raise(
          "Documentation could not be found. " <>
            "Please ensure documentation is in the doc/ or docs/ directory"
        )
    end
  end

  defp create_release(build, organization, auth, opts) do
    meta = build.meta
    %{tarball: tarball, outer_checksum: checksum} = Hex.Tar.create!(meta, meta.files, :memory)
    dry_run? = Keyword.get(opts, :dry_run, false)

    if dry_run? do
      :ok
    else
      send_release(tarball, checksum, organization, auth, opts)
    end
  end

  defp send_release(tarball, checksum, organization, auth, opts) do
    progress? = Keyword.get(opts, :progress, true)
    progress = progress_fun(progress?, byte_size(tarball))

    replace? = Keyword.get(opts, :replace, false)

    case Hex.API.Release.publish(organization, tarball, auth, progress, replace?) do
      {:ok, {code, body, _}} when code in 200..299 ->
        location = body["html_url"] || body["url"]
        checksum = String.downcase(Base.encode16(checksum, case: :lower))
        Hex.Shell.info("")
        Hex.Shell.info("Package published to #{location} (#{checksum})")
        :ok

      other ->
        Hex.Shell.info("")
        Hex.Shell.error("Publishing failed")
        Hex.Utils.print_error_result(other)
        :error
    end
  end

  defp progress_fun(true, size), do: Mix.Tasks.Hex.progress(size)
  defp progress_fun(false, _size), do: Mix.Tasks.Hex.progress(nil)
end

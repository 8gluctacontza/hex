defmodule Mix.Tasks.Hex.Publish do
  use Mix.Task
  alias Mix.Tasks.Hex.Build

  @shortdoc "Publishes a new package version"

  @moduledoc """
  Publishes a new version of your package and its documentation.

      mix hex.publish package

  If it is a new package being published it will be created and the user
  specified in `username` will be the package owner. Only package owners can
  publish.

  A published version can be amended or reverted with `--revert` up to one hour
  after its publication. Older packages can not be reverted.

      mix hex.publish docs

  The documentation will be accessible at `https://hexdocs.pm/my_package/1.0.0`,
  `https://hexdocs.pm/my_package` will always redirect to the latest published
  version.

  Documentation will be generated by running the `mix docs` task. `ex_doc`
  provides this task by default, but any library can be used. Or an alias can be
  used to extend the documentation generation. The expected result of the task
  is the generated documentation located in the `doc/` directory with an
  `index.html` file.

  Note that if you want to publish a new version of your package and its
  documentation in one step, you can use the following shorthand:

      mix hex.publish

  ## Command line options

    * `--revert VERSION` - Revert given version

  ## Configuration

    * `:app` - Package name (required).

    * `:version` - Package version (required).

    * `:deps` - List of package dependencies (see Dependencies below).

    * `:description` - Short description of the project.

    * `:package` - Hex specific configuration (see Package configuration below).

  ## Dependencies

  Dependencies are defined in mix's dependency format. But instead of using
  `:git` or `:path` as the SCM `:package` is used.

      defp deps do
        [{:ecto, "~> 0.1.0"},
        {:postgrex, "~> 0.3.0"},
        {:cowboy, github: "extend/cowboy"}]
      end

  As can be seen Hex package dependencies works alongside git dependencies.
  Important to note is that non-Hex dependencies will not be used during
  dependency resolution and neither will be they listed as dependencies of the
  package.

  ## Package configuration

  Additional metadata of the package can optionally be defined, but it is very
  recommended to do so.

    * `:name` - Set this if the package name is not the same as the application
       name.

    * `:files` - List of files and directories to include in the package,
      can include wildcards. Defaults to `["lib", "priv", "mix.exs", "README*",
      "readme*", "LICENSE*", "license*", "CHANGELOG*", "changelog*", "src"]`.

    * `:maintainers` - List of names and/or emails of maintainers.

    * `:licenses` - List of licenses used by the package.

    * `:links` - Map of links relevant to the package.

    * `:build_tools` - List of build tools that can build the package. Hex will
      try to automatically detect the build tools, it will do this based on the
      files in the package. If a "rebar" or "rebar.config" file is present Hex
      will mark it as able to build with rebar. This detection can be overridden
      by setting this field.
  """

  @switches [revert: :string, progress: :boolean, canonical: :string]

  def run(args) do
    Hex.start

    {opts, args, _} = OptionParser.parse(args, switches: @switches)
    config = Hex.Config.read
    build = Build.prepare_package
    revert_version = opts[:revert]
    revert = !!revert_version

    case args do
      ["package"] when revert ->
        auth = Mix.Tasks.Hex.auth_info(config)
        revert_package(build, revert_version, auth)
      ["docs"] when revert ->
        auth = Mix.Tasks.Hex.auth_info(config)
        revert_docs(build, revert_version, auth)
      [] when revert ->
        auth = Mix.Tasks.Hex.auth_info(config)
        revert(build, revert_version, auth)
      ["package"] ->
        auth = Mix.Tasks.Hex.auth_info(config)
        if proceed?(build), do: create_release(build, auth, opts)
      ["docs"] ->
        auth = Mix.Tasks.Hex.auth_info(config)
        docs_task(build, opts)
        create_docs(build, auth, opts)
      [] ->
        auth = Mix.Tasks.Hex.auth_info(config)
        create(build, auth, opts)
      _ ->
        Mix.raise """
        Invalid arguments, expected one of:
        mix hex.publish
        mix hex.publish package
        mix hex.publish docs
        """
    end
  end

  defp create(build, auth, opts) do
    if proceed?(build) do
      Hex.Shell.info("Building docs...")
      docs_task(build, opts)
      Hex.Shell.info("Publishing package...")
      if :ok == create_release(build, auth, opts) do
        Hex.Shell.info("Publishing docs...")
        create_docs(build, auth, opts)
      end
    end
  end

  defp create_docs(build, auth, opts) do
    directory = docs_dir()
    name = build.meta.name
    version = build.meta.version

    unless File.exists?("#{directory}/index.html") do
      Mix.raise "File not found: #{directory}/index.html"
    end

    progress? = Keyword.get(opts, :progress, true)
    tarball = build_tarball(name, version, directory)
    send_tarball(name, version, tarball, auth, progress?)
  end

  defp docs_task(build, opts) do
    name = build.meta.name

    canonical = opts[:canonical] || Hex.Utils.hexdocs_url(name)
    args = ["--canonical", canonical]
    try do
      Mix.Task.run("docs", args)
    rescue ex in [Mix.NoTaskError] ->
      stacktrace = System.stacktrace
      Mix.shell.error ~s(The "docs" task is unavailable. Please add {:ex_doc, ">= 0.0.0", only: :dev} ) <>
                      ~s(to your dependencies in your mix.exs. If ex_doc was already added, make sure ) <>
                      ~s(you run the task in the same environment it is configured to)
      reraise ex, stacktrace
    end
  end

  defp proceed?(build) do
    meta = build.meta
    exclude_deps = build.exclude_deps
    package = build.package

    Hex.Shell.info("Publishing #{meta.name} #{meta.version}")
    Build.print_info(meta, exclude_deps, package[:files])

    print_link_to_coc()

    Hex.Shell.yes?("Proceed?")
  end

  defp print_link_to_coc() do
    Hex.Shell.info "Before publishing, please read the Code of Conduct: https://hex.pm/policies/codeofconduct"
  end

  defp revert(build, version, auth) do
    Hex.Shell.info("Reverting package...")
    revert_package(build, version, auth)
    Hex.Shell.info("Reverting docs...")
    revert_docs(build, version, auth)
  end

  defp revert_package(build, version, auth) do
    version = Mix.Tasks.Hex.clean_version(version)
    name = build.meta.name

    case Hex.API.Release.delete(name, version, auth) do
      {:ok, {code, _, _}} when code in 200..299 ->
        Hex.Shell.info("Reverted #{name} #{version}")
      other ->
        Hex.Shell.error("Reverting #{name} #{version} failed")
        Hex.Utils.print_error_result(other)
    end
  end

  defp revert_docs(build, version, auth) do
    version = Mix.Tasks.Hex.clean_version(version)
    name = build.meta.name

    case Hex.API.ReleaseDocs.delete(name, version, auth) do
      {:ok, {code, _, _}} when code in 200..299 ->
        Hex.Shell.info "Reverted docs for #{name} #{version}"
      other ->
        Hex.Shell.error "Reverting docs for #{name} #{version} failed"
        Hex.Utils.print_error_result(other)
    end
  end

  defp build_tarball(name, version, directory) do
    tarball = "#{name}-#{version}-docs.tar.gz"
    files = files(directory)
    :ok = :hex_erl_tar.create(tarball, files, [:compressed])
    data = File.read!(tarball)

    File.rm!(tarball)
    data
  end

  defp send_tarball(name, version, tarball, auth, progress?) do
    progress = progress_fun(progress?, byte_size(tarball))

    case Hex.API.ReleaseDocs.new(name, version, tarball, auth, progress) do
      {:ok, {code, _, _}} when code in 200..299 ->
        Hex.Shell.info ""
        Hex.Shell.info "Docs published to #{Hex.Utils.hexdocs_url(name, version)}"
        :ok
      {:ok, {404, _, _}} ->
        Hex.Shell.info ""
        Hex.Shell.error "Publishing docs failed due to the package not being published yet"
        :error
      other ->
        Hex.Shell.info ""
        Hex.Shell.error "Publishing docs failed"
        Hex.Utils.print_error_result(other)
        :error
    end
  end

  defp files(directory) do
    "#{directory}/**"
    |> Path.wildcard
    |> Enum.filter(&File.regular?/1)
    |> Enum.map(&{relative_path(&1, directory), File.read!(&1)})
  end

  defp relative_path(file, dir) do
    Path.relative_to(file, dir)
    |> Hex.string_to_charlist
  end

  defp docs_dir do
    cond do
      File.exists?("doc") ->
        "doc"
      File.exists?("docs") ->
        "docs"
      true ->
        Mix.raise("Documentation could not be found. Please ensure documentation is in the doc/ or docs/ directory")
    end
  end

  defp create_release(build, auth, opts) do
    meta = build.meta
    {tarball, checksum} = Hex.Tar.create(meta, meta.files)
    progress? = Keyword.get(opts, :progress, true)
    progress = progress_fun(progress?, byte_size(tarball))

    case Hex.API.Release.new(meta.name, tarball, auth, progress) do
      {:ok, {code, _, _}} when code in 200..299 ->
        location = Hex.Utils.hex_package_url(meta.name, meta.version)
        Hex.Shell.info ""
        Hex.Shell.info("Package published to #{location} (#{String.downcase(checksum)})")
        :ok
      other ->
        Hex.Shell.info ""
        Hex.Shell.error("Publishing failed")
        Hex.Utils.print_error_result(other)
        :error
    end
  end

  defp progress_fun(true, size), do: Mix.Tasks.Hex.progress(size)
  defp progress_fun(false, _size), do: Mix.Tasks.Hex.progress(nil)
end

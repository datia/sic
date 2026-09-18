<br/>
<p align="center">
    <a href="https://www.isel.pt/en" target="_blank">
        <img width="50%" src="https://www.isel.pt/sites/default/files/001_imagens_isel/Logotipos/ISEL%202025/01_ISEL-Logotipo-RGB_Horizontal-Compacto-900┬║.png" alt="ISEL logo">
    </a>
</p>

<br/>
<p align="center">
    <a href="https://github.com/datia/sic/?tab=MIT-1-ov-file" target="_blank">
        <img src="https://img.shields.io/github/license/datia/sic" alt="GitHub license">
    </a>
</p>
<br/>

# Support material for Reliable Computer Systems master course @ [ISEL](http://www.isel.pt)

The course give students competences on designing modern informatics systems (IS).
For more details about the course check this [page](https://www.isel.pt/sites/default/files/FUC_202526_4453.pdf).

## Dependencies

This base development kit uses [Docker](https://www.docker.com) to setup a [PostgreSQL](https://www.postgresql.org/docs/17/index.html) relational database.

It is necessary to install Docker in you computer to use this kit.

## Usage

To start the container, run the command `docker compose up` in the directory where `docker-compose.yml` is. Do note that for some instalations you may need to uso `sudo.`
The `setup-master` directory stores initialization scripts to bootstrap the database.
The `data` directory will have the database files after the database initialization.
**To create a fresh installation of the database just delete the data directory**

Tested using Docker Desktop 4.54 in Mac Tahoe (Apple Silicon)

## License

[![MIT license](https://img.shields.io/badge/License-MIT-blue.svg)](https://choosealicense.com/licenses/mit/)

![maintained](https://img.shields.io/badge/Maintained%3F-yes-green.svg)
